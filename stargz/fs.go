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

//
// Example implementation of FileSystem.
//
// This implementation uses stargz by CRFS(https://github.com/google/crfs) as
// image format, which has following feature:
// - We can use docker registry as a backend store (means w/o additional layer
//   stores).
// - The stargz-formatted image is still docker-compatible (means normal
//   runtimes can still use the formatted image).
//
// Currently, we reimplemented CRFS-like filesystem for ease of integration.
// But in the near future, we intend to integrate it with CRFS.
//

package stargz

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/containerd/containerd/log"
	"github.com/containerd/containerd/reference/docker"
	"github.com/google/crfs/stargz"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"
	"github.com/hanwen/go-fuse/fuse"
	"github.com/hanwen/go-fuse/fuse/nodefs"
	"github.com/ktock/stargz-snapshotter/cache"
	snbase "github.com/ktock/stargz-snapshotter/snapshot"
	"github.com/ktock/stargz-snapshotter/stargz/reader"
	"github.com/ktock/stargz-snapshotter/stargz/remote"
	"github.com/ktock/stargz-snapshotter/task"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"golang.org/x/sys/unix"
)

const (
	blockSize         = 512
	memoryCacheType   = "memory"
	whiteoutPrefix    = ".wh."
	whiteoutOpaqueDir = whiteoutPrefix + whiteoutPrefix + ".opq"
	opaqueXattr       = "trusted.overlay.opaque"
	opaqueXattrValue  = "y"
	stateDirName      = ".stargz-snapshotter"

	targetRefLabel    = "containerd.io/snapshot/remote/stargz.reference"
	targetDigestLabel = "containerd.io/snapshot/remote/stargz.digest"
	targetSizeLabel   = "containerd.io/snapshot/remote/stargz.size"
	annotationRefName = "containerd.io/unpacker/ref.name"

	defaultHTTPCacheChunkSize = 50000
	defaultLRUCacheEntry      = 5000
	defaultLayerValidInterval = 60 * time.Second
)

type layer interface {
	OpenFile(name string) (io.ReaderAt, error)
}

type remoteInfo interface {
	FetchedSize() int64
	Check() error
}

type Config struct {
	LRUCacheEntry      int    `toml:"lru_max_entry"`
	HTTPCacheChunkSize int64  `toml:"http_chunk_size"`
	HTTPCacheType      string `toml:"http_cache_type"`
	FSCacheType        string `toml:"filesystem_cache_type"`
	LayerValidInterval int64  `toml:"layer_valid_interval"`
	CheckLayerAlways   bool   `toml:"check_layer_always"`

	Insecure   []string `toml:"insecure"`
	NoPrefetch bool     `toml:"noprefetch"`
	Debug      bool     `toml:"debug"`
}

// getCache gets a cache corresponding to specified type.
func getCache(ctype, dir string, maxEntry int) (cache.BlobCache, error) {
	if ctype == memoryCacheType {
		return cache.NewMemoryCache(), nil
	}
	return cache.NewDirectoryCache(dir, maxEntry)
}

func NewFilesystem(root string, config *Config) (snbase.FileSystem, error) {
	httpCacheChunkSize := config.HTTPCacheChunkSize
	if httpCacheChunkSize == 0 {
		httpCacheChunkSize = defaultHTTPCacheChunkSize
	}
	maxEntry := config.LRUCacheEntry
	if maxEntry == 0 {
		maxEntry = defaultLRUCacheEntry
	}
	httpCache, err := getCache(config.HTTPCacheType, filepath.Join(root, "httpcache"), maxEntry)
	if err != nil {
		return nil, err
	}
	fsCache, err := getCache(config.FSCacheType, filepath.Join(root, "fscache"), maxEntry)
	if err != nil {
		return nil, err
	}
	var layerValidInterval time.Duration
	if config.LayerValidInterval == 0 {
		layerValidInterval = defaultLayerValidInterval // zero means "use default interval"
	} else {
		layerValidInterval = time.Duration(config.LayerValidInterval) * time.Second
	}
	if config.CheckLayerAlways {
		layerValidInterval = 0
	}

	return &filesystem{
		httpCacheChunkSize:    httpCacheChunkSize,
		httpCache:             httpCache,
		fsCache:               fsCache,
		noprefetch:            config.NoPrefetch,
		insecure:              config.Insecure,
		pullTransports:        make(map[string]http.RoundTripper),
		layerValidInterval:    layerValidInterval,
		remoteInfo:            make(map[string]remoteInfo),
		backgroundTaskManager: task.NewBackgroundTaskManager(2, 5*time.Second),
		debug:                 config.Debug,
	}, nil
}

type filesystem struct {
	httpCacheChunkSize    int64
	httpCache             cache.BlobCache
	fsCache               cache.BlobCache
	noprefetch            bool
	insecure              []string
	pullTransports        map[string]http.RoundTripper
	pullTransportsMu      sync.Mutex
	layerValidInterval    time.Duration
	remoteInfo            map[string]remoteInfo
	remoteInfoMu          sync.Mutex
	backgroundTaskManager *task.BackgroundTaskManager
	debug                 bool
}

type readerAtFunc func([]byte, int64) (int, error)

func (f readerAtFunc) ReadAt(p []byte, offset int64) (int, error) { return f(p, offset) }

func (fs *filesystem) Mount(ctx context.Context, mountpoint string, labels map[string]string) error {
	// This is a prioritized task and all background tasks will be stopped
	// execution so this can avoid being disturbed for NW traffic by background
	// tasks.
	fs.backgroundTaskManager.DoPrioritizedTask()
	defer fs.backgroundTaskManager.DonePrioritizedTask()

	// Get basic information of this layer.
	ref, ok := labels[targetRefLabel]
	if !ok {
		log.G(ctx).Debug("reference hasn't been passed")
		return fmt.Errorf("reference hasn't been passed")
	}
	digest, ok := labels[targetDigestLabel]
	if !ok {
		log.G(ctx).WithField("ref", ref).Debug("digest hasn't been passed")
		return fmt.Errorf("digest hasn't been passed")
	}
	sizeLabel, ok := labels[targetSizeLabel]
	if !ok {
		log.G(ctx).WithField("ref", ref).Debug("size hasn't been passed")
		return fmt.Errorf("size hasn't been passed")
	}
	size, err := strconv.ParseInt(sizeLabel, 10, 64)
	if err != nil {
		log.G(ctx).WithError(err).WithField("ref", ref).Debug("failed to parse size")
		return fmt.Errorf("failed to parse size: %v", err)
	}

	// Authenticate to the registry using ~/.docker/config.json.
	url, tr, err := fs.resolve(ref, digest)
	if err != nil {
		log.G(ctx).WithField("ref", ref).
			WithField("digest", digest).
			Debug("failed to resolve the reference")
		return err
	}

	// Make and register a reader for the remote blob of this layer.
	ur, err := remote.NewURLReaderAt(
		url,
		tr,
		size,
		fs.httpCacheChunkSize,
		fs.httpCache,
		fs.layerValidInterval)
	if err != nil {
		log.G(ctx).WithError(err).
			WithField("ref", ref).
			WithField("digest", digest).
			WithField("url", url).
			Debug("failed to connect")
		return err
	}
	fs.remoteInfoMu.Lock()
	fs.remoteInfo[mountpoint] = ur
	fs.remoteInfoMu.Unlock()

	// Get a reader for stargz archive.
	// Each file's read operation is a prioritized task and all background tasks
	// will be stopped during the execution so this can avoid being disturbed for
	// NW traffic by background tasks.
	sr := io.NewSectionReader(readerAtFunc(func(p []byte, offset int64) (n int, err error) {
		fs.backgroundTaskManager.DoPrioritizedTask()
		defer fs.backgroundTaskManager.DonePrioritizedTask()
		return ur.ReadAt(p, offset)
	}), 0, size)
	gr, root, err := reader.NewReader(sr, fs.fsCache)
	if err != nil {
		log.G(ctx).WithError(err).
			WithField("ref", ref).
			WithField("digest", digest).
			WithField("url", url).
			Debug("failed to read layer")
		return err
	}

	// Prefetch this layer
	if !fs.noprefetch {
		cache, err := gr.Prefetch() // TODO: make sync/async switchable
		if err != nil {
			log.G(ctx).WithError(err).
				WithField("ref", ref).
				WithField("digest", digest).
				WithField("url", url).
				Debug("failed to prefetch layer")
			return err
		}
		go func() {
			if err := cache(); err != nil {
				log.G(ctx).WithError(err).
					WithField("ref", ref).
					WithField("digest", digest).
					WithField("url", url).
					Debug("failed to cache prefetched layer")
				return
			}
			log.G(ctx).WithError(err).
				WithField("ref", ref).
				WithField("digest", digest).
				WithField("url", url).
				Debug("completed to prefetch")
		}()
	}

	// Fetch whole layer aggressively in background. We use background
	// reader for this so prioritized tasks(Mount, Check, etc...) can
	// interrupt the reading. This can avoid disturbing prioritized tasks
	// about NW traffic. We read layer with a buffer to reduce num of
	// requests to the registry.
	// this fetching functionality can be interrupted by prioritized tasks.
	go func() {
		br := io.NewSectionReader(readerAtFunc(func(p []byte, offset int64) (n int, err error) {
			fs.backgroundTaskManager.InvokeBackgroundTask(func(ctx context.Context) {
				n, err = ur.ReadAtWithContext(ctx, p, offset)
			}, 120*time.Second)
			return
		}), 0, size)
		if err := gr.FetchTarGzWithReader(br); err != nil {
			log.G(ctx).WithError(err).
				WithField("ref", ref).
				WithField("digest", digest).
				WithField("url", url).
				Debug("failed to fetch whole layer")
			return
		}
		log.G(ctx).WithError(err).
			WithField("ref", ref).
			WithField("digest", digest).
			WithField("url", url).
			Debug("completed to fetch all layer data in background")
	}()

	// Mounting stargz
	// TODO: bind mount the state directory as a read-only fs on snapshotter's side
	conn := nodefs.NewFileSystemConnector(&node{
		Node:  nodefs.NewDefaultNode(),
		fs:    fs,
		layer: gr,
		e:     root,
		s:     newState(digest, ur, size),
		root:  mountpoint,
	}, &nodefs.Options{
		NegativeTimeout: 0,
		AttrTimeout:     time.Second,
		EntryTimeout:    time.Second,
		Owner:           nil, // preserve owners.
	})
	server, err := fuse.NewServer(conn.RawFS(), mountpoint, &fuse.MountOptions{AllowOther: true})
	if err != nil {
		log.G(ctx).WithError(err).
			WithField("ref", ref).
			WithField("digest", digest).
			WithField("url", url).
			Debug("failed to make filesstem server")
		return err
	}

	server.SetDebug(fs.debug)
	go server.Serve()
	return server.WaitMount()
}

func (fs *filesystem) Check(ctx context.Context, mountpoint string) error {
	// This is a prioritized task and all background tasks will be stopped
	// execution so this can avoid being disturbed for NW traffic by background
	// tasks.
	fs.backgroundTaskManager.DoPrioritizedTask()
	defer fs.backgroundTaskManager.DonePrioritizedTask()

	fs.remoteInfoMu.Lock()
	r := fs.remoteInfo[mountpoint]
	fs.remoteInfoMu.Unlock()
	if r == nil {
		log.G(ctx).WithField("mountpoint", mountpoint).
			Debug("check failed: reader not registered")
		return fmt.Errorf("reader not regisiterd")
	}
	if err := r.Check(); err != nil {
		log.G(ctx).WithError(err).
			WithField("mountpoint", mountpoint).
			Debug("check failed")
		return err
	}

	return nil
}

func (fs *filesystem) Annotate(ctx context.Context, desc ocispec.Descriptor) (map[string]string, error) {
	ref, ok := desc.Annotations[annotationRefName]
	if !ok {
		log.G(ctx).WithField("desc", desc.Digest).Debug("reference not passed")
		return nil, fmt.Errorf("reference not passed")
	}
	return map[string]string{
		targetRefLabel:    ref,
		targetDigestLabel: desc.Digest.String(),
		targetSizeLabel:   fmt.Sprintf("%d", desc.Size),
	}, nil
}

func (fs *filesystem) unregisterRemote(mountpoint string) {
	fs.remoteInfoMu.Lock()
	delete(fs.remoteInfo, mountpoint)
	fs.remoteInfoMu.Unlock()
}

// resolve resolves specified reference with authenticating and dealing with
// redirection in a proper way. We use `~/.docker/config.json` for authn.
func (fs *filesystem) resolve(ref string, digest string) (string, http.RoundTripper, error) {
	fs.pullTransportsMu.Lock()
	defer fs.pullTransportsMu.Unlock()

	// Parse reference in docker convention
	named, err := docker.ParseDockerRef(ref)
	if err != nil {
		return "", nil, err
	}
	var (
		scheme = "https"
		host   = docker.Domain(named)
		path   = docker.Path(named)
		opts   []name.Option
	)
	if host == "docker.io" {
		host = "registry-1.docker.io"
	}
	for _, i := range fs.insecure {
		if ok, _ := regexp.Match(i, []byte(host)); ok {
			scheme = "http"
			opts = append(opts, name.Insecure)
			break
		}
	}
	url := fmt.Sprintf("%s://%s/v2/%s/blobs/%s", scheme, host, path, digest)
	nameref, err := name.ParseReference(fmt.Sprintf("%s/%s", host, path), opts...)
	if err != nil {
		return "", nil, fmt.Errorf("failed to parse reference %q: %v", ref, err)
	}

	// Try to use cached transport (cahced per reference name)
	tr, ok := fs.pullTransports[nameref.Name()]
	if ok {
		// Check the connectivity of the transport (and redirect if necessary)
		if url, err := checkAndRedirect(url, tr); err == nil {
			return url, tr, nil
		}
	}

	// Refresh the transport and check the connectivity
	if tr, err = refreshTransport(nameref); err != nil {
		return "", nil, err
	}
	if url, err = checkAndRedirect(url, tr); err != nil {
		return "", nil, err
	}

	// Update transports cache
	fs.pullTransports[nameref.Name()] = tr

	return url, tr, nil
}

func refreshTransport(ref name.Reference) (http.RoundTripper, error) {
	// Authn against the repository using `~/.docker/config.json`
	auth, err := authn.DefaultKeychain.Resolve(ref.Context())
	if err != nil {
		return nil, fmt.Errorf("failed to resolve the reference %q: %v", ref, err)
	}
	return transport.New(ref.Context().Registry, auth, http.DefaultTransport, []string{ref.Scope(transport.PullScope)})
}

func checkAndRedirect(url string, tr http.RoundTripper) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// We use GET request for GCR.
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("failed to request to the registry of %q: %v", url, err)
	}
	req = req.WithContext(ctx)
	req.Close = false
	req.Header.Set("Range", "bytes=0-1")
	res, err := tr.RoundTrip(req)
	if err != nil || res.StatusCode >= 400 {
		return "", fmt.Errorf("failed to redirect: %v", err)
	}
	defer func() {
		io.Copy(ioutil.Discard, res.Body)
		res.Body.Close()
	}()
	if redir := res.Header.Get("Location"); redir != "" && res.StatusCode/100 == 3 {
		url = redir
	}
	return url, nil
}

// node is a filesystem inode abstraction which implements node in go-fuse.
type node struct {
	nodefs.Node
	fs     *filesystem
	layer  layer
	e      *stargz.TOCEntry
	s      *state
	root   string
	opaque bool // true if this node is an overlayfs opaque directory
}

func (n *node) OnUnmount() {
	n.fs.unregisterRemote(n.root)
}

func (n *node) OpenDir(context *fuse.Context) ([]fuse.DirEntry, fuse.Status) {
	var ents []fuse.DirEntry
	whiteouts := map[string]*stargz.TOCEntry{}
	normalEnts := map[string]bool{}
	n.e.ForeachChild(func(baseName string, ent *stargz.TOCEntry) bool {

		// We don't want to show prefetch landmark in "/".
		if n.e.Name == "" && baseName == reader.PrefetchLandmark {
			return true
		}

		// We don't want to show whiteouts.
		if strings.HasPrefix(baseName, whiteoutPrefix) {
			if baseName == whiteoutOpaqueDir {
				return true
			}
			// Add the overlayfs-compiant whiteout later.
			whiteouts[baseName] = ent
			return true
		}

		// This is a normal entry.
		normalEnts[baseName] = true
		ents = append(ents, fuse.DirEntry{
			Mode: fileModeToSystemMode(ent.Stat().Mode()),
			Name: baseName,
			Ino:  inodeOfEnt(ent),
		})
		return true
	})

	// Append whiteouts if no entry replaces the target entry in the lower layer.
	for w, ent := range whiteouts {
		if !normalEnts[w[len(whiteoutPrefix):]] {
			ents = append(ents, fuse.DirEntry{
				Mode: syscall.S_IFCHR,
				Name: w[len(whiteoutPrefix):],
				Ino:  inodeOfEnt(ent),
			})

		}
	}

	// Append state directory in "/".
	if n.e.Name == "" {
		ents = append(ents, fuse.DirEntry{
			Mode: syscall.S_IFDIR | n.s.mode(),
			Name: stateDirName,
			Ino:  n.s.ino(),
		})
	}

	sort.Slice(ents, func(i, j int) bool { return ents[i].Name < ents[j].Name })
	return ents, fuse.OK
}

func (n *node) Lookup(out *fuse.Attr, name string, context *fuse.Context) (*nodefs.Inode, fuse.Status) {
	c := n.Inode().GetChild(name)
	if c != nil {
		s := c.Node().GetAttr(out, nil, context)
		if s != fuse.OK {
			return nil, s
		}
		return c, fuse.OK
	}

	// We don't want to show prefetch landmark in "/".
	if n.e.Name == "" && name == reader.PrefetchLandmark {
		return nil, fuse.ENOENT
	}

	// We don't want to show whiteouts.
	if strings.HasPrefix(name, whiteoutPrefix) {
		return nil, fuse.ENOENT
	}

	// state directory
	if n.e.Name == "" && name == stateDirName {
		return n.Inode().NewChild(name, true, n.s), n.s.attr(out)
	}

	ce, ok := n.e.LookupChild(name)
	if !ok {
		// If the entry exists as a whiteout, show an overlayfs-styled whiteout node.
		if wh, ok := n.e.LookupChild(fmt.Sprintf("%s%s", whiteoutPrefix, name)); ok {
			return n.Inode().NewChild(name, false, &whiteout{
				Node: nodefs.NewDefaultNode(),
				oe:   wh,
			}), entryToWhAttr(wh, out)
		}
		return nil, fuse.ENOENT
	}
	var opaque bool
	if _, ok := ce.LookupChild(whiteoutOpaqueDir); ok {
		// This entry is an opaque directory so make it recognizable for overlayfs.
		opaque = true
	}
	return n.Inode().NewChild(name, ce.Stat().IsDir(), &node{
		Node:   nodefs.NewDefaultNode(),
		fs:     n.fs,
		layer:  n.layer,
		e:      ce,
		s:      n.s,
		root:   n.root,
		opaque: opaque,
	}), entryToAttr(ce, out)
}

func (n *node) Access(mode uint32, context *fuse.Context) fuse.Status {
	if context.Owner.Uid == 0 {
		// root can do anything.
		return fuse.OK
	}
	if mode == 0 {
		// Requires nothing.
		return fuse.OK
	}

	var shift uint32
	if uint32(n.e.Uid) == context.Owner.Uid {
		shift = 6
	} else if uint32(n.e.Gid) == context.Owner.Gid {
		shift = 3
	} else {
		shift = 0
	}
	if mode<<shift&fileModeToSystemMode(n.e.Stat().Mode()) != 0 {
		return fuse.OK
	}

	return fuse.EPERM
}

func (n *node) Open(flags uint32, context *fuse.Context) (nodefs.File, fuse.Status) {
	ra, err := n.layer.OpenFile(n.e.Name)
	if err != nil {
		n.s.report(fmt.Errorf("failed to open node: %v", err))
		return nil, fuse.EIO
	}
	return &file{
		File: nodefs.NewDefaultFile(),
		n:    n,
		e:    n.e,
		ra:   ra,
	}, fuse.OK
}

func (n *node) GetAttr(out *fuse.Attr, file nodefs.File, context *fuse.Context) fuse.Status {
	return entryToAttr(n.e, out)
}

func (n *node) GetXAttr(attribute string, context *fuse.Context) ([]byte, fuse.Status) {
	if attribute == opaqueXattr && n.opaque {
		// This node is an opaque directory so give overlayfs-compliant indicator.
		return []byte(opaqueXattrValue), fuse.OK
	}
	if v, ok := n.e.Xattrs[attribute]; ok {
		return v, fuse.OK
	}
	return nil, fuse.ENOATTR
}

func (n *node) ListXAttr(ctx *fuse.Context) (attrs []string, code fuse.Status) {
	if n.opaque {
		// This node is an opaque directory so add overlayfs-compliant indicator.
		attrs = append(attrs, opaqueXattr)
	}
	for k := range n.e.Xattrs {
		attrs = append(attrs, k)
	}
	return attrs, fuse.OK
}

func (n *node) Readlink(c *fuse.Context) ([]byte, fuse.Status) {
	return []byte(n.e.LinkName), fuse.OK
}
func (n *node) Deletable() bool {
	// read-only filesystem
	return false
}

func (n *node) StatFs() *fuse.StatfsOut {
	return defaultStatfs()
}

// file is a file abstraction which implements file in go-fuse.
type file struct {
	nodefs.File
	n  *node
	e  *stargz.TOCEntry
	ra io.ReaderAt
}

func (f *file) String() string {
	return "stargzFile"
}

func (f *file) Read(buf []byte, off int64) (fuse.ReadResult, fuse.Status) {
	n, err := f.ra.ReadAt(buf, off)
	if err != nil && err != io.EOF {
		f.n.s.report(fmt.Errorf("failed to read node: %v", err))
		return nil, fuse.EIO
	}
	return fuse.ReadResultData(buf[:n]), fuse.OK
}

func (f *file) GetAttr(out *fuse.Attr) fuse.Status {
	return entryToAttr(f.e, out)
}

// whiteout is a whiteout abstraction compliant to overlayfs. This implements
// node in go-fuse.
type whiteout struct {
	nodefs.Node
	oe *stargz.TOCEntry
}

func (w *whiteout) GetAttr(out *fuse.Attr, file nodefs.File, context *fuse.Context) fuse.Status {
	return entryToWhAttr(w.oe, out)
}

// newState provides new state directory node.
// It creates statFile at the same time to give it stable inode number.
func newState(digest string, ri remoteInfo, size int64) *state {
	return &state{
		Node: nodefs.NewDefaultNode(),
		statFile: &statFile{
			Node: nodefs.NewDefaultNode(),
			name: digest + ".json",
			statJSON: statJSON{
				Digest: digest,
				Size:   size,
			},
			ri: ri,
		},
	}
}

// state is a directory which contain a "state file" of this layer aming to
// observability. This filesystem uses it to report something(e.g. error) to
// the clients(e.g. Kubernetes's livenessProbe).
// This directory has mode "dr-x------ root root".
type state struct {
	nodefs.Node
	statFile *statFile
}

func (s *state) report(err error) {
	s.statFile.report(err)
}

func (s *state) OpenDir(context *fuse.Context) ([]fuse.DirEntry, fuse.Status) {
	return []fuse.DirEntry{
		{
			Mode: syscall.S_IFREG | s.statFile.mode(),
			Name: s.statFile.name,
			Ino:  s.statFile.ino(),
		},
	}, fuse.OK
}

func (s *state) Lookup(out *fuse.Attr, name string, context *fuse.Context) (*nodefs.Inode, fuse.Status) {
	if c := s.Inode().GetChild(name); c != nil {
		if status := c.Node().GetAttr(out, nil, context); status != fuse.OK {
			return nil, status
		}
		return c, fuse.OK
	}

	if name != s.statFile.name {
		return nil, fuse.ENOENT
	}
	return s.Inode().NewChild(name, false, s.statFile), s.statFile.attr(out)
}

func (s *state) Access(mode uint32, context *fuse.Context) fuse.Status {
	if mode == 0 {
		// Requires nothing.
		return fuse.OK
	}
	if context.Owner.Uid == 0 && mode&s.mode()>>6 != 0 {
		// root can read and open it (dr-x------ root root).
		return fuse.OK
	}

	return fuse.EPERM

}
func (s *state) GetAttr(out *fuse.Attr, file nodefs.File, context *fuse.Context) fuse.Status {
	return s.attr(out)
}

func (s *state) StatFs() *fuse.StatfsOut {
	return defaultStatfs()
}

func (s *state) ino() uint64 {
	// calculates the inode number which is one-to-one conresspondence
	// with this state directory node inscance.
	return uint64(uintptr(unsafe.Pointer(s)))
}

func (s *state) mode() uint32 {
	return 0500
}

func (s *state) attr(out *fuse.Attr) fuse.Status {
	out.Ino = s.ino()
	out.Size = 0
	out.Blksize = blockSize
	out.Blocks = 0
	out.Mode = syscall.S_IFDIR | s.mode()
	out.Owner = fuse.Owner{Uid: 0, Gid: 0}
	out.Nlink = 1

	// dummy
	out.Mtime = 0
	out.Mtimensec = 0
	out.Rdev = 0
	out.Padding = 0

	return fuse.OK
}

type statJSON struct {
	Error  string `json:"error,omitempty"`
	Digest string `json:"digest"`
	// URL is excluded for potential security reason
	Size           int64   `json:"size"`
	FetchedSize    int64   `json:"fetchedSize"`
	FetchedPercent float64 `json:"fetchedPercent"` // Fetched / Size * 100.0
}

// statFile is a file which contain something to be reported from this layer.
// This filesystem uses statFile.report() to report something(e.g. error) to
// the clients(e.g. Kubernetes's livenessProbe).
// This directory has mode "-r-------- root root".
type statFile struct {
	nodefs.Node
	name     string
	ri       remoteInfo
	statJSON statJSON
	mu       sync.Mutex
}

func (e *statFile) report(err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.statJSON.Error = err.Error()
}

func (e *statFile) updateStatUnlocked() ([]byte, error) {
	e.statJSON.FetchedSize = e.ri.FetchedSize()
	e.statJSON.FetchedPercent = float64(e.statJSON.FetchedSize) / float64(e.statJSON.Size) * 100.0
	j, err := json.Marshal(&e.statJSON)
	if err != nil {
		return nil, err
	}
	j = append(j, []byte("\n")...)
	return j, nil
}

func (e *statFile) Access(mode uint32, context *fuse.Context) fuse.Status {
	if mode == 0 {
		// Requires nothing.
		return fuse.OK
	}
	if context.Owner.Uid == 0 && mode&e.mode()>>6 != 0 {
		// root can operate it.
		return fuse.OK
	}

	return fuse.EPERM
}

func (e *statFile) Open(flags uint32, context *fuse.Context) (nodefs.File, fuse.Status) {
	return nil, fuse.OK
}

func (e *statFile) Read(file nodefs.File, dest []byte, off int64, context *fuse.Context) (fuse.ReadResult, fuse.Status) {
	e.mu.Lock()
	defer e.mu.Unlock()
	st, err := e.updateStatUnlocked()
	if err != nil {
		return nil, fuse.EIO
	}
	n, err := bytes.NewReader(st).ReadAt(dest, off)
	if err != nil && err != io.EOF {
		return nil, fuse.EIO
	}
	return fuse.ReadResultData(dest[:n]), fuse.OK
}

func (e *statFile) GetAttr(out *fuse.Attr, file nodefs.File, context *fuse.Context) fuse.Status {
	return e.attr(out)
}

func (e *statFile) StatFs() *fuse.StatfsOut {
	return defaultStatfs()
}

func (e *statFile) ino() uint64 {
	// calculates the inode number which is one-to-one conresspondence
	// with this state file node inscance.
	return uint64(uintptr(unsafe.Pointer(e)))
}

func (e *statFile) mode() uint32 {
	return 0400
}

func (e *statFile) attr(out *fuse.Attr) fuse.Status {
	e.mu.Lock()
	defer e.mu.Unlock()

	st, err := e.updateStatUnlocked()
	if err != nil {
		return fuse.EIO
	}

	out.Ino = e.ino()
	out.Size = uint64(len(st))
	out.Blksize = blockSize
	out.Blocks = out.Size / uint64(out.Blksize)
	out.Mode = syscall.S_IFREG | e.mode()
	out.Owner = fuse.Owner{Uid: 0, Gid: 0}
	out.Nlink = 1

	// dummy
	out.Mtime = 0
	out.Mtimensec = 0
	out.Rdev = 0
	out.Padding = 0

	return fuse.OK
}

// inodeOfEnt calculates the inode number which is one-to-one conresspondence
// with the TOCEntry insntance.
func inodeOfEnt(e *stargz.TOCEntry) uint64 {
	return uint64(uintptr(unsafe.Pointer(e)))
}

// entryToAttr converts stargz's TOCEntry to go-fuse's Attr.
func entryToAttr(e *stargz.TOCEntry, out *fuse.Attr) fuse.Status {
	fi := e.Stat()
	out.Ino = inodeOfEnt(e)
	out.Size = uint64(fi.Size())
	out.Blksize = blockSize
	out.Blocks = out.Size / uint64(out.Blksize)
	if out.Size%uint64(out.Blksize) > 0 {
		out.Blocks++
	}
	out.Mtime = uint64(fi.ModTime().Unix())
	out.Mtimensec = uint32(fi.ModTime().UnixNano())
	out.Mode = fileModeToSystemMode(fi.Mode())
	out.Owner = fuse.Owner{Uid: uint32(e.Uid), Gid: uint32(e.Gid)}
	out.Rdev = uint32(unix.Mkdev(uint32(e.DevMajor), uint32(e.DevMinor)))
	out.Nlink = uint32(e.NumLink)
	if out.Nlink == 0 {
		out.Nlink = 1 // zero "NumLink" means one.
	}
	out.Padding = 0 // TODO

	return fuse.OK
}

// entryToWhAttr converts stargz's TOCEntry to go-fuse's Attr of whiteouts.
func entryToWhAttr(e *stargz.TOCEntry, out *fuse.Attr) fuse.Status {
	fi := e.Stat()
	out.Ino = inodeOfEnt(e)
	out.Size = 0
	out.Blksize = blockSize
	out.Blocks = 0
	out.Mtime = uint64(fi.ModTime().Unix())
	out.Mtimensec = uint32(fi.ModTime().UnixNano())
	out.Mode = syscall.S_IFCHR
	out.Owner = fuse.Owner{Uid: 0, Gid: 0}
	out.Rdev = uint32(unix.Mkdev(0, 0))
	out.Nlink = 1
	out.Padding = 0 // TODO

	return fuse.OK
}

// fileModeToSystemMode converts os.FileMode to system's native bitmap.
func fileModeToSystemMode(m os.FileMode) uint32 {
	sm := uint32(m & 0777)
	switch m & os.ModeType {
	case os.ModeDevice:
		sm |= syscall.S_IFBLK
	case os.ModeDevice | os.ModeCharDevice:
		sm |= syscall.S_IFCHR
	case os.ModeDir:
		sm |= syscall.S_IFDIR
	case os.ModeNamedPipe:
		sm |= syscall.S_IFIFO
	case os.ModeSymlink:
		sm |= syscall.S_IFLNK
	case os.ModeSocket:
		sm |= syscall.S_IFSOCK
	default: // regular file.
		sm |= syscall.S_IFREG
	}
	if m&os.ModeSetgid != 0 {
		sm |= syscall.S_ISGID
	}
	if m&os.ModeSetuid != 0 {
		sm |= syscall.S_ISUID
	}
	if m&os.ModeSticky != 0 {
		sm |= syscall.S_ISVTX
	}

	return sm
}

func defaultStatfs() *fuse.StatfsOut {
	// http://man7.org/linux/man-pages/man2/statfs.2.html
	return &fuse.StatfsOut{
		Blocks:  0, // dummy
		Bfree:   0,
		Bavail:  0,
		Files:   0, // dummy
		Ffree:   0,
		Bsize:   blockSize,
		NameLen: 1<<32 - 1,
		Frsize:  blockSize,
		Padding: 0,
		Spare:   [6]uint32{},
	}
}
