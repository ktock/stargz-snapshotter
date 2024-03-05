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

package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"

	streamingapi "github.com/containerd/containerd/v2/api/services/streaming/v1"
	transfertypes "github.com/containerd/containerd/v2/api/types/transfer"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/reference"
	"github.com/containerd/containerd/v2/pkg/streaming"
	"github.com/containerd/containerd/v2/plugins/snapshots/overlay/overlayutils"
	"github.com/containerd/containerd/v2/protobuf"
	"github.com/containerd/errdefs"
	"github.com/containerd/log"
	stargzfs "github.com/containerd/stargz-snapshotter/fs"
	"github.com/containerd/stargz-snapshotter/fs/layer"
	"github.com/containerd/stargz-snapshotter/fs/source"
	"github.com/containerd/stargz-snapshotter/metadata"
	esgzexternaltoc "github.com/containerd/stargz-snapshotter/nativeconverter/estargz/externaltoc"
	"github.com/containerd/stargz-snapshotter/service/resolver"
	snbase "github.com/containerd/stargz-snapshotter/snapshot"
	"github.com/containerd/typeurl/v2"
	"github.com/hashicorp/go-multierror"
	rhttp "github.com/hashicorp/go-retryablehttp"
	digest "github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

type Option func(*options)

type options struct {
	credsFuncs    []resolver.Credential
	registryHosts source.RegistryHosts
	fsOpts        []stargzfs.Option
}

// WithCredsFuncs specifies credsFuncs to be used for connecting to the registries.
func WithCredsFuncs(creds ...resolver.Credential) Option {
	return func(o *options) {
		o.credsFuncs = append(o.credsFuncs, creds...)
	}
}

// WithCustomRegistryHosts is registry hosts to use instead.
func WithCustomRegistryHosts(hosts source.RegistryHosts) Option {
	return func(o *options) {
		o.registryHosts = hosts
	}
}

// WithFilesystemOptions allowes to pass filesystem-related configuration.
func WithFilesystemOptions(opts ...stargzfs.Option) Option {
	return func(o *options) {
		o.fsOpts = opts
	}
}

// NewStargzSnapshotterService returns stargz snapshotter.
func NewStargzSnapshotterService(ctx context.Context, root string, config *Config, opts ...Option) (snapshots.Snapshotter, error) {
	var sOpts options
	for _, o := range opts {
		o(&sOpts)
	}

	hosts := sOpts.registryHosts
	if hosts == nil {
		// Use RegistryHosts based on ResolverConfig and keychain
		hosts = resolver.RegistryHostsFromConfig(resolver.Config(config.ResolverConfig), sOpts.credsFuncs...)
	}

	userxattr, err := overlayutils.NeedsUserXAttr(snapshotterRoot(root))
	if err != nil {
		log.G(ctx).WithError(err).Warnf("cannot detect whether \"userxattr\" option needs to be used, assuming to be %v", userxattr)
	}
	opq := layer.OverlayOpaqueTrusted
	if userxattr {
		opq = layer.OverlayOpaqueUser
	}
	// Configure filesystem and snapshotter
	fsOpts := append(sOpts.fsOpts, stargzfs.WithGetSources(sources(
		fromCRILabelsWithAuthStream(config.ContainerdTransferKeychainConfig, resolver.Config(config.ResolverConfig), sOpts.credsFuncs...), // TODO: we should disable this if sOpts.registryHosts != nil because we can't configure these hosts to use stream auth.
		sourceFromCRILabels(hosts),      // provides source info based on CRI labels
		source.FromDefaultLabels(hosts), // provides source info based on default labels
	)),
		stargzfs.WithOverlayOpaqueType(opq),
		stargzfs.WithAdditionalDecompressors(func(ctx context.Context, hosts source.RegistryHosts, refspec reference.Spec, desc ocispec.Descriptor) []metadata.Decompressor {
			return []metadata.Decompressor{esgzexternaltoc.NewRemoteDecompressor(ctx, hosts, refspec, desc)}
		}),
	)
	fs, err := stargzfs.NewFilesystem(fsRoot(root), config.Config, fsOpts...)
	if err != nil {
		log.G(ctx).WithError(err).Fatalf("failed to configure filesystem")
	}

	var snapshotter snapshots.Snapshotter

	snOpts := []snbase.Opt{snbase.AsynchronousRemove}
	if config.SnapshotterConfig.AllowInvalidMountsOnRestart {
		snOpts = append(snOpts, snbase.AllowInvalidMountsOnRestart)
	}

	snapshotter, err = snbase.NewSnapshotter(ctx, snapshotterRoot(root), fs, snOpts...)
	if err != nil {
		log.G(ctx).WithError(err).Fatalf("failed to create new snapshotter")
	}

	return snapshotter, err
}

func snapshotterRoot(root string) string {
	return filepath.Join(root, "snapshotter")
}

func fsRoot(root string) string {
	return filepath.Join(root, "stargz")
}

func sources(ps ...source.GetSources) source.GetSources {
	return func(labels map[string]string) (source []source.Source, allErr error) {
		for _, p := range ps {
			if p == nil {
				continue
			}
			src, err := p(labels)
			if err == nil {
				return src, nil
			}
			allErr = multierror.Append(allErr, err)
		}
		return
	}
}

// Supported returns nil when the remote snapshotter is functional on the system with the root directory.
// Supported is not called during plugin initialization, but exposed for downstream projects which uses
// this snapshotter as a library.
func Supported(root string) error {
	// Remote snapshotter is implemented based on overlayfs snapshotter.
	return overlayutils.Supported(snapshotterRoot(root))
}

const defaultRequestTimeoutSec = 30

func fromCRILabelsWithAuthStream(config ContainerdTransferKeychainConfig, cfg resolver.Config, credsFuncs ...resolver.Credential) source.GetSources {
	ctx := namespaces.WithNamespace(context.Background(), config.ContainerdNamespace)
	ctd, err := containerd.New(config.ContainerdAddress)
	if err != nil {
		return nil
	}
	return func(labels map[string]string) ([]source.Source, error) {
		hosts := func(ref reference.Spec) (hosts []docker.RegistryHost, _ error) {
			host := ref.Hostname()
			for _, h := range append(cfg.Host[host].Mirrors, resolver.MirrorConfig{
				Host: host,
			}) {
				client := rhttp.NewClient()
				client.Logger = nil // disable logging every request
				if h.RequestTimeoutSec >= 0 {
					if h.RequestTimeoutSec == 0 {
						client.HTTPClient.Timeout = defaultRequestTimeoutSec * time.Second
					} else {
						client.HTTPClient.Timeout = time.Duration(h.RequestTimeoutSec) * time.Second
					}
				} // h.RequestTimeoutSec < 0 means "no timeout"
				tr := client.StandardClient()
				var header http.Header
				var err error
				if h.Header != nil {
					header = http.Header{}
					for key, ty := range h.Header {
						switch value := ty.(type) {
						case string:
							header[key] = []string{value}
						case []interface{}:
							header[key], err = makeStringSlice(value, nil)
							if err != nil {
								return nil, err
							}
						default:
							return nil, fmt.Errorf("invalid type %v for header %q", ty, key)
						}
					}
				}
				credsFuncs := credsFuncs
				ctx := namespaces.WithNamespace(ctx, config.ContainerdNamespace)
				if f := credsFuncFromAuthStreamLabel(ctx, ctd, labels); f != nil {
					credsFuncs = append(credsFuncs, f)
				}
				config := docker.RegistryHost{
					Client:       tr,
					Host:         h.Host,
					Scheme:       "https",
					Path:         "/v2",
					Capabilities: docker.HostCapabilityPull | docker.HostCapabilityResolve,
					Authorizer: docker.NewDockerAuthorizer(
						docker.WithAuthClient(tr),
						docker.WithAuthCreds(multiCredsFuncs(ref, credsFuncs...))),
					Header: header,
				}
				if localhost, _ := docker.MatchLocalhost(config.Host); localhost || h.Insecure {
					config.Scheme = "http"
				}
				if config.Host == "docker.io" {
					config.Host = "registry-1.docker.io"
				}
				hosts = append(hosts, config)
			}
			return
		}
		refStr, ok := labels[targetRefLabel]
		if !ok {
			return nil, fmt.Errorf("reference hasn't been passed")
		}
		refspec, err := reference.Parse(refStr)
		if err != nil {
			return nil, err
		}

		digestStr, ok := labels[targetLayerDigestLabel]
		if !ok {
			return nil, fmt.Errorf("digest hasn't been passed")
		}
		target, err := digest.Parse(digestStr)
		if err != nil {
			return nil, err
		}

		var neighboringLayers []ocispec.Descriptor
		if l, ok := labels[targetImageLayersLabel]; ok {
			layersStr := strings.Split(l, ",")
			for i, l := range layersStr {
				d, err := digest.Parse(l)
				if err != nil {
					return nil, err
				}
				if d.String() != target.String() {
					desc := ocispec.Descriptor{Digest: d}
					if urls, ok := labels[targetImageURLsLabelPrefix+fmt.Sprintf("%d", i)]; ok {
						desc.URLs = strings.Split(urls, ",")
					}
					neighboringLayers = append(neighboringLayers, desc)
				}
			}
		}

		targetDesc := ocispec.Descriptor{
			Digest:      target,
			Annotations: labels,
		}
		if targetURLs, ok := labels[targetURLsLabel]; ok {
			targetDesc.URLs = append(targetDesc.URLs, strings.Split(targetURLs, ",")...)
		}

		return []source.Source{
			{
				Hosts:    hosts,
				Name:     refspec,
				Target:   targetDesc,
				Manifest: ocispec.Manifest{Layers: append([]ocispec.Descriptor{targetDesc}, neighboringLayers...)},
			},
		}, nil
	}
}

var streams = make(map[string]resolver.Credential)

var mu sync.Mutex

func credsFuncFromAuthStreamLabel(ctx context.Context, c *containerd.Client, labels map[string]string) resolver.Credential {
	mu.Lock()
	defer mu.Unlock()
	id, ok := labels["containerd.io/snapshot/creds-stream"]
	if !ok {
		return nil
	}
	if f, ok := streams[id]; ok {
		return f
	}
	sc := streamingapi.NewStreamingClient(c.Conn())
	stream, err := sc.Stream(ctx)
	if err != nil {
		return nil
	}

	a, err := typeurl.MarshalAny(&streamingapi.StreamInit{
		ID: id,
	})
	if err != nil {
		return nil
	}
	err = stream.Send(protobuf.FromAny(a))
	if err != nil {
		if !errors.Is(err, io.EOF) {
			err = errdefs.FromGRPC(err)
		}
		return nil
	}

	// Receive an ack that stream is init and ready
	if _, err = stream.Recv(); err != nil {
		if !errors.Is(err, io.EOF) && !errdefs.IsAlreadyExists(err) {
			err = errdefs.FromGRPC(err)
			return nil
		}
	}

	f := (&credCallback{
		stream: &clientStream{stream},
	}).getCredentials
	streams[id] = f
	return f
}

type clientStream struct {
	s streamingapi.Streaming_StreamClient
}

func (cs *clientStream) Send(a typeurl.Any) (err error) {
	err = cs.s.Send(protobuf.FromAny(a))
	if !errors.Is(err, io.EOF) {
		err = errdefs.FromGRPC(err)
	}
	return
}

func (cs *clientStream) Recv() (a typeurl.Any, err error) {
	a, err = cs.s.Recv()
	if !errors.Is(err, io.EOF) {
		err = errdefs.FromGRPC(err)
	}
	return
}

func (cs *clientStream) Close() error {
	return cs.s.CloseSend()
}

type Credentials struct {
	Host     string
	Username string
	Secret   string
	Header   string
}

type credCallback struct {
	sync.Mutex
	stream streaming.Stream
}

func (cc *credCallback) getCredentials(host string, refspec reference.Spec) (string, string, error) {
	cc.Lock()
	defer cc.Unlock()

	ar := &transfertypes.AuthRequest{
		Host:      host,
		Reference: refspec.String(),
	}
	anyType, err := typeurl.MarshalAny(ar)
	if err != nil {
		return "", "", err
	}
	if err := cc.stream.Send(anyType); err != nil {
		return "", "", err
	}
	resp, err := cc.stream.Recv()
	if err != nil {
		return "", "", err
	}
	var s transfertypes.AuthResponse
	if err := typeurl.UnmarshalTo(resp, &s); err != nil {
		return "", "", err
	}
	creds := Credentials{
		Host: host,
	}
	switch s.AuthType {
	case transfertypes.AuthType_CREDENTIALS:
		creds.Username = s.Username
		creds.Secret = s.Secret
	case transfertypes.AuthType_REFRESH:
		creds.Secret = s.Secret
	case transfertypes.AuthType_HEADER:
		creds.Header = s.Secret
	}

	// TODO: return header
	return creds.Username, creds.Secret, nil
}

func multiCredsFuncs(ref reference.Spec, credsFuncs ...resolver.Credential) func(string) (string, string, error) {
	return func(host string) (string, string, error) {
		for _, f := range credsFuncs {
			if username, secret, err := f(host, ref); err != nil {
				return "", "", err
			} else if !(username == "" && secret == "") {
				return username, secret, nil
			}
		}
		return "", "", nil
	}
}

// makeStringSlice is a helper func to convert from []interface{} to []string.
// Additionally an optional cb func may be passed to perform string mapping.
// NOTE: Ported from https://github.com/containerd/containerd/blob/v1.6.9/remotes/docker/config/hosts.go#L516-L533
func makeStringSlice(slice []interface{}, cb func(string) string) ([]string, error) {
	out := make([]string, len(slice))
	for i, value := range slice {
		str, ok := value.(string)
		if !ok {
			return nil, fmt.Errorf("unable to cast %v to string", value)
		}

		if cb != nil {
			out[i] = cb(str)
		} else {
			out[i] = str
		}
	}
	return out, nil
}
