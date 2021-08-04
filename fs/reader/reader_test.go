/*
   Copyright The containerd Authors.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

/*
   Copyright 2019 The Go Authors. All rights reserved.
   Use of this source code is governed by a BSD-style
   license that can be found in the NOTICE.md file.
*/

package reader

import (
	"bytes"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"strings"
	"testing"

	"github.com/containerd/stargz-snapshotter/cache"
	"github.com/containerd/stargz-snapshotter/estargz"
	"github.com/containerd/stargz-snapshotter/metadata"
	"github.com/containerd/stargz-snapshotter/util/testutil"
	digest "github.com/opencontainers/go-digest"
	bolt "go.etcd.io/bbolt"
)

const (
	sampleChunkSize    = 3
	sampleMiddleOffset = sampleChunkSize / 2
	sampleData1        = "0123456789"
	lastChunkOffset1   = sampleChunkSize * (int64(len(sampleData1)) / sampleChunkSize)
)

// Tests Reader for failure cases.
func TestFailReader(t *testing.T) {
	testFileName := "test"
	stargzFile, _, err := testutil.BuildEStargz([]testutil.TarEntry{
		testutil.File(testFileName, sampleData1),
	}, testutil.WithEStargzOptions(estargz.WithChunkSize(sampleChunkSize)))
	if err != nil {
		t.Fatalf("failed to build sample estargz")
	}
	br := &breakReaderAt{
		ReaderAt: stargzFile,
		success:  true,
	}
	bev := &testChunkVerifier{true}
	mcache := cache.NewMemoryCache()
	gr, closeFn, err := newReader(io.NewSectionReader(br, 0, stargzFile.Size()), mcache, digest.Digest(""), bev)
	if err != nil {
		t.Fatalf("Failed to open stargz file: %v", err)
	}
	defer closeFn()

	notexist := uint32(0)
	found := false
	for i := uint32(0); i < 1000000; i++ {
		if _, err := gr.Metadata().GetAttr(i); err != nil {
			notexist, found = i, true
			break
		}
	}
	if !found {
		t.Fatalf("free ID not found")
	}

	// tests for opening file
	_, err = gr.OpenFile(notexist)
	if err == nil {
		t.Errorf("succeeded to open file but wanted to fail")
		return
	}

	tid, _, err := gr.Metadata().GetChild(gr.Metadata().RootID(), testFileName)
	if err != nil {
		t.Errorf("failed to get %q: %v", testFileName, err)
		return
	}
	fr, err := gr.OpenFile(tid)
	if err != nil {
		t.Errorf("failed to open file but wanted to succeed: %v", err)
		return
	}

	for _, rs := range []bool{true, false} {
		for _, vs := range []bool{true, false} {
			mcache.(*cache.MemoryCache).Membuf = map[string]*bytes.Buffer{}
			br.success = rs
			bev.success = vs

			// tests for reading file
			p := make([]byte, len(sampleData1))
			n, err := fr.ReadAt(p, 0)
			if rs && vs {
				if err != nil || n != len(sampleData1) || !bytes.Equal([]byte(sampleData1), p) {
					t.Errorf("failed to read data but wanted to succeed: %v", err)
					return
				}
			} else {
				if err == nil {
					t.Errorf("succeeded to read data but wanted to fail (reader:%v,verify:%v)", rs, vs)
					return
				}
			}

			// tests for caching reader
			err = gr.Cache()
			if rs && vs {
				if err != nil {
					t.Errorf("failed to cache reader but wanted to succeed")
				}
			} else {
				if err == nil {
					t.Errorf("succeeded to cache reader but wanted to fail (reader:%v,verify:%v)", rs, vs)
				}
			}

		}
	}
}

type breakReaderAt struct {
	io.ReaderAt
	success bool
}

func (br *breakReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if br.success {
		return br.ReaderAt.ReadAt(p, off)
	}
	return 0, fmt.Errorf("failed")
}

type testChunkVerifier struct {
	success bool
}

func (bev *testChunkVerifier) Verifier(id uint32, chunkOffset, chunkSize int64) (digest.Verifier, error) {
	return &testVerifier{bev.success}, nil
}

type testVerifier struct {
	success bool
}

func (bv *testVerifier) Write(p []byte) (n int, err error) {
	return len(p), nil
}

func (bv *testVerifier) Verified() bool {
	return bv.success
}

type region struct{ b, e int64 }

// Tests ReadAt method of each file.
func TestFileReadAt(t *testing.T) {
	sizeCond := map[string]int64{
		"single_chunk": sampleChunkSize - sampleMiddleOffset,
		"multi_chunks": sampleChunkSize + sampleMiddleOffset,
	}
	innerOffsetCond := map[string]int64{
		"at_top":    0,
		"at_middle": sampleMiddleOffset,
	}
	baseOffsetCond := map[string]int64{
		"of_1st_chunk":  sampleChunkSize * 0,
		"of_2nd_chunk":  sampleChunkSize * 1,
		"of_last_chunk": lastChunkOffset1,
	}
	fileSizeCond := map[string]int64{
		"in_1_chunk_file":  sampleChunkSize * 1,
		"in_2_chunks_file": sampleChunkSize * 2,
		"in_max_size_file": int64(len(sampleData1)),
	}
	cacheCond := map[string][]region{
		"with_clean_cache": nil,
		"with_edge_filled_cache": {
			region{0, sampleChunkSize - 1},
			region{lastChunkOffset1, int64(len(sampleData1)) - 1},
		},
		"with_sparse_cache": {
			region{0, sampleChunkSize - 1},
			region{2 * sampleChunkSize, 3*sampleChunkSize - 1},
		},
	}
	for sn, size := range sizeCond {
		for in, innero := range innerOffsetCond {
			for bo, baseo := range baseOffsetCond {
				for fn, filesize := range fileSizeCond {
					for cc, cacheExcept := range cacheCond {
						t.Run(fmt.Sprintf("reading_%s_%s_%s_%s_%s", sn, in, bo, fn, cc), func(t *testing.T) {
							if filesize > int64(len(sampleData1)) {
								t.Fatal("sample file size is larger than sample data")
							}

							wantN := size
							offset := baseo + innero
							if remain := filesize - offset; remain < wantN {
								if wantN = remain; wantN < 0 {
									wantN = 0
								}
							}

							// use constant string value as a data source.
							want := strings.NewReader(sampleData1)

							// data we want to get.
							wantData := make([]byte, wantN)
							_, err := want.ReadAt(wantData, offset)
							if err != nil && err != io.EOF {
								t.Fatalf("want.ReadAt (offset=%d,size=%d): %v", offset, wantN, err)
							}

							// data we get through a file.
							f, closeFn := makeFile(t, []byte(sampleData1)[:filesize], sampleChunkSize)
							defer closeFn()
							f.ra = newExceptSectionReader(t, f.ra, cacheExcept...)
							for _, reg := range cacheExcept {
								id := genID(f.id, reg.b, reg.e-reg.b+1)
								w, err := f.cache.Add(id)
								if err != nil {
									w.Close()
									t.Fatalf("failed to add cache %v: %v", id, err)
								}
								if _, err := w.Write([]byte(sampleData1[reg.b : reg.e+1])); err != nil {
									w.Close()
									t.Fatalf("failed to write cache %v: %v", id, err)
								}
								if err := w.Commit(); err != nil {
									w.Close()
									t.Fatalf("failed to commit cache %v: %v", id, err)
								}
								w.Close()
							}
							respData := make([]byte, size)
							n, err := f.ReadAt(respData, offset)
							if err != nil {
								t.Errorf("failed to read off=%d, size=%d, filesize=%d: %v", offset, size, filesize, err)
								return
							}
							respData = respData[:n]

							if !bytes.Equal(wantData, respData) {
								t.Errorf("off=%d, filesize=%d; read data{size=%d,data=%q}; want (size=%d,data=%q)",
									offset, filesize, len(respData), string(respData), wantN, string(wantData))
								return
							}

							// check cache has valid contents.
							cn := 0
							nr := 0
							for int64(nr) < wantN {
								chunkOffset, chunkSize, ok := f.r.ChunkEntryForOffset(f.id, offset+int64(nr))
								if !ok {
									break
								}
								data := make([]byte, chunkSize)
								id := genID(f.id, chunkOffset, chunkSize)
								r, err := f.cache.Get(id)
								if err != nil {
									t.Errorf("missed cache of offset=%d, size=%d: %v(got size=%d)", chunkOffset, chunkSize, err, n)
									return
								}
								defer r.Close()
								if n, err := r.ReadAt(data, 0); (err != nil && err != io.EOF) || n != int(chunkSize) {
									t.Errorf("failed to read cache of offset=%d, size=%d: %v(got size=%d)", chunkOffset, chunkSize, err, n)
									return
								}
								nr += n
								cn++
							}
						})
					}
				}
			}
		}
	}
}

type exceptSectionReader struct {
	ra     io.ReaderAt
	except map[region]bool
	t      *testing.T
}

func newExceptSectionReader(t *testing.T, ra io.ReaderAt, except ...region) io.ReaderAt {
	er := exceptSectionReader{ra: ra, t: t}
	er.except = map[region]bool{}
	for _, reg := range except {
		er.except[reg] = true
	}
	return &er
}

func (er *exceptSectionReader) ReadAt(p []byte, offset int64) (int, error) {
	if er.except[region{offset, offset + int64(len(p)) - 1}] {
		er.t.Fatalf("Requested prohibited region of chunk: (%d, %d)", offset, offset+int64(len(p))-1)
	}
	return er.ra.ReadAt(p, offset)
}

func makeFile(t *testing.T, contents []byte, chunkSize int) (*file, func()) {
	testName := "test"
	sr, dgst, err := testutil.BuildEStargz([]testutil.TarEntry{
		testutil.File(testName, string(contents)),
	}, testutil.WithEStargzOptions(estargz.WithChunkSize(chunkSize)))
	if err != nil {
		t.Fatalf("failed to build sample estargz")
	}
	r, closeFn, err := newReader(sr, cache.NewMemoryCache(), dgst, nil)
	if err != nil {
		t.Fatalf("Failed to open stargz file: %v", err)
	}
	tid, _, err := r.Metadata().GetChild(r.Metadata().RootID(), testName)
	if err != nil {
		t.Fatalf("failed to get %q: %v", testName, err)
	}
	ra, err := r.OpenFile(tid)
	if err != nil {
		t.Fatalf("Failed to open testing file: %v", err)
	}
	f, ok := ra.(*file)
	if !ok {
		t.Fatalf("invalid type of file %q", tid)
	}
	return f, closeFn
}

func newReader(sr *io.SectionReader, cache cache.BlobCache, dgst digest.Digest, ev metadata.ChunkVerifier) (*reader, func(), error) {
	f, err := ioutil.TempFile("", "readertest")
	if err != nil {
		return nil, nil, err
	}
	db, err := bolt.Open(f.Name(), 0666, nil)
	if err != nil {
		return nil, nil, err
	}
	telemetry := &metadata.Telemetry{}
	vr, err := NewReader(db, sr, cache, telemetry)
	if err != nil {
		return nil, nil, err
	}
	var r *reader
	if ev != nil {
		r = vr.r
		r.verifier = ev
	} else {
		rr, err := vr.VerifyTOC(dgst)
		if err != nil {
			return nil, nil, err
		}
		r = rr.(*reader)
	}
	return r, func() { os.Remove(f.Name()); f.Close() }, err
}
