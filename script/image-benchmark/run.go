package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/containerd/containerd"
	"github.com/containerd/containerd/content"
	"github.com/containerd/containerd/images"
	"github.com/containerd/containerd/images/converter"
	"github.com/containerd/containerd/namespaces"
	"github.com/containerd/containerd/platforms"
	"github.com/containerd/stargz-snapshotter/estargz"
	esgzexternaltoc "github.com/containerd/stargz-snapshotter/estargz/externaltoc"
	estargzconvert "github.com/containerd/stargz-snapshotter/nativeconverter/estargz"
	esgzexternaltocconvert "github.com/containerd/stargz-snapshotter/nativeconverter/estargz/externaltoc"
	"github.com/containerd/stargz-snapshotter/util/containerdutil"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"golang.org/x/sync/errgroup"
)

type result struct {
	name         string
	srcImageSize int64
	newImageSize int64
	readTimeAvg  float64
}

func main() {
	tests := []struct {
		name             string
		layerConvertFunc func() (converter.ConvertFunc, finalizeFunc)
		openEStargz      openEStargzFunc
	}{
		{"min-chunk-size=0", layerConverter(estargzconvert.LayerConvertFunc(estargz.WithMinChunkSize(0))), openEStargz},
		{"min-chunk-size=0,externalTOC", layerConverterExternalTOC(gzip.BestCompression, estargz.WithMinChunkSize(0)), openEStargzExternalTOC},
		{"min-chunk-size=1000", layerConverter(estargzconvert.LayerConvertFunc(estargz.WithMinChunkSize(1000))), openEStargz},
		{"min-chunk-size=1000,externalTOC", layerConverterExternalTOC(gzip.BestCompression, estargz.WithMinChunkSize(1000)), openEStargzExternalTOC},
		{"min-chunk-size=10000", layerConverter(estargzconvert.LayerConvertFunc(estargz.WithMinChunkSize(10000))), openEStargz},
		{"min-chunk-size=10000,externalTOC", layerConverterExternalTOC(gzip.BestCompression, estargz.WithMinChunkSize(10000)), openEStargzExternalTOC},
		{"min-chunk-size=25000", layerConverter(estargzconvert.LayerConvertFunc(estargz.WithMinChunkSize(25000))), openEStargz},
		{"min-chunk-size=25000,externalTOC", layerConverterExternalTOC(gzip.BestCompression, estargz.WithMinChunkSize(25000)), openEStargzExternalTOC},
		{"min-chunk-size=50000", layerConverter(estargzconvert.LayerConvertFunc(estargz.WithMinChunkSize(50000))), openEStargz},
		{"min-chunk-size=50000,externalTOC", layerConverterExternalTOC(gzip.BestCompression, estargz.WithMinChunkSize(50000)), openEStargzExternalTOC},
	}

	var results []result
	ref := os.Args[1]
	for _, c := range tests {
		fmt.Println(c.name)
		cf, finalize := c.layerConvertFunc()
		res, done, err := getReader(ref, cf, finalize, c.openEStargz)
		if err != nil {
			panic(err)
		}
		defer done()
		fmt.Printf("size of image: %d / %d = %v (%v B)\n", res.newImageSize, res.srcImageSize, float64(res.newImageSize)/float64(res.srcImageSize), res.newImageSize-res.srcImageSize)
		var totalTime time.Duration
		readNum := 0
		for i, er := range res.layerReaders {
			// Open and read file
			files := res.layerFiles[i]
			for j := 0; j < len(files); j++ {
				now := time.Now()
				sr, err := er.OpenFile(files[j])
				if err != nil {
					panic(err)
				}
				_, err = io.ReadAll(sr)
				if err != nil {
					panic(err)
				}
				lap := time.Now().Sub(now)
				totalTime = totalTime + lap
				readNum++
			}
		}
		avg := float64(totalTime) / float64(readNum)
		fmt.Printf("Average time to read file: %v\n", time.Duration(avg))
		fmt.Println("")
		results = append(results, result{
			name:         c.name,
			srcImageSize: res.srcImageSize,
			newImageSize: res.newImageSize,
			readTimeAvg:  avg,
		})
	}
	fmt.Println("Image size and time to read files (eStargz vs original image)")
	fmt.Println("|benchmark|estargz/original (increased size)|average time to read file|")
	fmt.Println("|---|---|---|")
	for _, res := range results {
		scale := math.Pow(10, math.Floor(math.Log10(res.readTimeAvg))+1-3)
		fmt.Printf("|%s|%.3f (%d B)|%v|\n", res.name, float64(res.newImageSize)/float64(res.srcImageSize), res.newImageSize-res.srcImageSize, time.Duration(scale*math.Trunc(res.readTimeAvg/scale)))
	}
}

type openEStargzFunc func(context.Context, ocispec.Descriptor, content.Store, *io.SectionReader, *images.Image) (*estargz.Reader, error)
type finalizeFunc func(ctx context.Context, cs content.Store, ref string, desc *ocispec.Descriptor) (*images.Image, error)

func layerConverter(l converter.ConvertFunc) func() (converter.ConvertFunc, finalizeFunc) {
	return func() (converter.ConvertFunc, finalizeFunc) {
		return l, nil
	}
}

func layerConverterExternalTOC(compressionLevel int, opts ...estargz.Option) func() (converter.ConvertFunc, finalizeFunc) {
	return func() (converter.ConvertFunc, finalizeFunc) {
		return esgzexternaltocconvert.LayerConvertFunc(opts, compressionLevel)
	}
}

func openEStargzExternalTOC(ctx context.Context, desc ocispec.Descriptor, cs content.Store, layerR *io.SectionReader, extraImg *images.Image) (*estargz.Reader, error) {
	return estargz.Open(layerR, estargz.WithDecompressors(esgzexternaltoc.NewGzipDecompressor(func() ([]byte, error) {
		b, err := getExtraTOCOfLayer(ctx, desc, cs, extraImg)
		if err != nil {
			return nil, fmt.Errorf("failed to get external TOC of %v: %w", desc.Digest, err)
		}
		return b, nil
	})))
}

func openEStargz(_ context.Context, _ ocispec.Descriptor, _ content.Store, layerR *io.SectionReader, _ *images.Image) (*estargz.Reader, error) {
	return estargz.Open(layerR)
}

const containerdAddr = "/run/containerd/containerd.sock" // TODO: make configurable

type imageInfo struct {
	srcImageSize int64
	newImageSize int64
	layerReaders []*estargz.Reader
	layerFiles   [][]string
}

func getReader(ref string, layerConvertFunc converter.ConvertFunc, finalize finalizeFunc, openEStargz openEStargzFunc) (*imageInfo, func() error, error) {
	client, err := containerd.New(containerdAddr)
	if err != nil {
		return nil, nil, err
	}
	ctx := namespaces.WithNamespace(context.TODO(), "default")
	ctx, done, err := client.WithLease(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer done(ctx)
	cs := client.ContentStore()

	targetRef := ref + "-esgz"
	newImg, err := converter.Convert(ctx, client, targetRef, ref,
		converter.WithPlatform(platforms.DefaultStrict()),
		converter.WithLayerConvertFunc(layerConvertFunc))
	if err != nil {
		return nil, nil, fmt.Errorf("failed to convert: %w", err)
	}
	var extraImg *images.Image
	if finalize != nil {
		eimg, err := finalize(ctx, cs, targetRef, &newImg.Target)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to finalize: %w", err)
		}
		is := client.ImageService()
		_ = is.Delete(ctx, eimg.Name)
		finimg, err := is.Create(ctx, *eimg)
		if err != nil {
			return nil, nil, err
		}
		extraImg = &finimg
	}

	if extraImg != nil {
		extraImgSize, err := extraImg.Size(ctx, cs, platforms.DefaultStrict())
		if err != nil {
			return nil, nil, err
		}
		fmt.Printf("size of extra image %d B\n", extraImgSize)
	}

	srcImg, err := client.ImageService().Get(ctx, ref)
	if err != nil {
		return nil, nil, err
	}
	srcLayers, err := getLayers(ctx, cs, &srcImg)
	if err != nil {
		return nil, nil, err
	}
	layers, err := getLayers(ctx, cs, newImg)
	if err != nil {
		return nil, nil, err
	}
	if len(layers) != len(srcLayers) {
		return nil, nil, fmt.Errorf("converted image has unexpected num of layers: %d; wanted %d", len(layers), len(srcLayers))
	}
	newImgSize, err := newImg.Size(ctx, cs, platforms.DefaultStrict())
	if err != nil {
		return nil, nil, err
	}
	srcImgSize, err := srcImg.Size(ctx, cs, platforms.DefaultStrict())
	if err != nil {
		return nil, nil, err
	}

	layerReaders := make([]*estargz.Reader, len(layers))
	layerFiles := make([][]string, len(layers))
	closeFuncs := []func() error{}
	var mu sync.Mutex
	eg := new(errgroup.Group)
	for i := 0; i < len(layers); i++ {
		i := i
		layer := layers[i]
		eg.Go(func() error {
			layerReader, err := cs.ReaderAt(ctx, ocispec.Descriptor{Digest: layer.Digest})
			if err != nil {
				return err
			}
			layerR := io.NewSectionReader(layerReader, 0, layer.Size)
			files, err := filesInLayer(layerR)
			if err != nil {
				return err
			}
			er, err := openEStargz(ctx, layer, cs, layerR, extraImg)
			if err != nil {
				return err
			}

			mu.Lock()
			closeFuncs = append(closeFuncs, layerReader.Close)
			layerReaders[i] = er
			layerFiles[i] = files
			mu.Unlock()

			return nil
		})
	}
	if err := eg.Wait(); err != nil {
		return nil, nil, err
	}

	for i := 0; i < len(layers); i++ {
		fmt.Printf("size of layer[%d] (%d): %d / %d = %v (%v B)\n",
			i,
			len(layerFiles[i]),
			layers[i].Size,
			srcLayers[i].Size,
			float64(layers[i].Size)/float64(srcLayers[i].Size),
			layers[i].Size-srcLayers[i].Size,
		)
	}

	return &imageInfo{
			srcImageSize: srcImgSize,
			newImageSize: newImgSize,
			layerReaders: layerReaders,
			layerFiles:   layerFiles,
		}, func() error {
			for _, f := range closeFuncs {
				if err := f(); err != nil {
					panic(err)
				}
			}
			return nil
		}, nil
}

func filesInLayer(r io.Reader) (files []string, err error) {
	gr, err := gzip.NewReader(r)
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(gr)
	for {
		h, err := tr.Next()
		if err != nil {
			if err == io.EOF {
				break
			}
			return nil, err
		}
		if h.Typeflag == tar.TypeReg && h.Name != "stargz.index.json" {
			files = append(files, cleanEntryName(h.Name))
		}
	}
	return files, nil
}

func cleanEntryName(name string) string {
	// Use path.Clean to consistently deal with path separators across platforms.
	return strings.TrimPrefix(path.Clean("/"+name), "/")
}

func getLayers(ctx context.Context, cs content.Store, newImg *images.Image) ([]ocispec.Descriptor, error) {
	manifestDesc, err := containerdutil.ManifestDesc(ctx, cs, newImg.Target, platforms.Any(ocispec.Platform{
		Architecture: "amd64",
		OS:           "linux",
	}))
	if err != nil {
		return nil, err
	}
	manifestReader, err := cs.ReaderAt(ctx, manifestDesc)
	if err != nil {
		return nil, err
	}
	manifestInfo, err := cs.Info(ctx, manifestDesc.Digest)
	if err != nil {
		return nil, err
	}
	manifestR := io.NewSectionReader(manifestReader, 0, manifestInfo.Size)
	var manifest ocispec.Manifest
	if err := json.NewDecoder(manifestR).Decode(&manifest); err != nil {
		return nil, err
	}
	return manifest.Layers, nil
}

func getExtraTOCOfLayer(ctx context.Context, desc ocispec.Descriptor, cs content.Store, extraImg *images.Image) ([]byte, error) {
	layers, err := getLayers(ctx, cs, extraImg)
	if err != nil {
		return nil, err
	}
	for _, l := range layers {
		if len(l.Annotations) == 0 {
			continue
		}
		ldgst, ok := l.Annotations["containerd.io/snapshot/stargz/layer.digest"]
		if !ok {
			continue
		}
		if ldgst == desc.Digest.String() {
			r, err := cs.ReaderAt(ctx, l)
			if err != nil {
				return nil, err
			}
			defer r.Close()
			return io.ReadAll(io.NewSectionReader(r, 0, l.Size))
		}
	}
	return nil, fmt.Errorf("TOC not found")
}
