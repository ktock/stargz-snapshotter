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

package cache

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/golang/groupcache/lru"
	"github.com/pkg/errors"
)

// TODO: contents validation.

type BlobCache interface {
	Fetch(blobHash string, p []byte) (int, error)
	Add(blobHash string, p []byte)
}

type dirOpt struct {
	syncAdd bool
}

type DirOption func(o *dirOpt) *dirOpt

func SyncAdd() DirOption {
	return func(o *dirOpt) *dirOpt {
		o.syncAdd = true
		return o
	}
}

func NewDirectoryCache(directory string, memCacheSize int, opts ...DirOption) (BlobCache, error) {
	opt := &dirOpt{}
	for _, o := range opts {
		opt = o(opt)
	}
	if err := os.MkdirAll(directory, os.ModePerm); err != nil {
		return nil, err
	}
	dc := &directoryCache{
		cache:     lru.New(memCacheSize),
		directory: directory,
		bufPool: sync.Pool{
			New: func() interface{} {
				return new(bytes.Buffer)
			},
		},
	}
	dc.cache.OnEvicted = func(_ lru.Key, value interface{}) {
		dc.bufPool.Put(value)
	}
	if opt.syncAdd {
		dc.syncAdd = true
	}
	return dc, nil
}

// directoryCache is a cache implementation which backend is a directory.
type directoryCache struct {
	cache     *lru.Cache
	cacheMu   sync.Mutex
	directory string
	syncAdd   bool
	fileMu    sync.Mutex

	bufPool sync.Pool
}

func (dc *directoryCache) Fetch(blobHash string, p []byte) (n int, err error) {
	dc.cacheMu.Lock()
	if cache, ok := dc.cache.Get(blobHash); ok {
		n = copy(p, cache.(*bytes.Buffer).Bytes())
		dc.cacheMu.Unlock()
		return
	}
	dc.cacheMu.Unlock()

	c := filepath.Join(dc.directory, blobHash[:2], blobHash)
	fi, err := os.Stat(c)
	if err != nil {
		return 0, errors.Wrapf(err, "Missed cache %q", c)
	}
	if fi.Size() != int64(len(p)) {
		return 0, fmt.Errorf("buffer size is invalid %d; want %d", len(p), fi.Size())
	}

	file, err := os.Open(c)
	if err != nil {
		return 0, errors.Wrapf(err, "failed to open blob file %q", c)
	}
	defer file.Close()

	b := dc.bufPool.Get().(*bytes.Buffer)
	b.Reset()
	if n, err = io.ReadFull(io.TeeReader(file, b), p); err != nil && err != io.EOF {
		return 0, errors.Wrapf(err, "failed to read cached data %q", c)
	} else if int64(n) != fi.Size() {
		return 0, fmt.Errorf("failed to copy full contents from cache %d; want %d", n, fi.Size())
	}
	dc.cacheMu.Lock()
	dc.cache.Add(blobHash, b)
	dc.cacheMu.Unlock()

	return
}

func (dc *directoryCache) Add(blobHash string, p []byte) {
	// Copy the original data for avoiding the cached contents to be edited accidentally
	b := dc.bufPool.Get().(*bytes.Buffer)
	b.Reset()
	b.Write(p)

	dc.cacheMu.Lock()
	dc.cache.Add(blobHash, b)
	dc.cacheMu.Unlock()

	// NOTE: We use another buffer for storing the data into the disk. We don't use
	// the cached buffer (`b`) here because this will possibly be evicted from
	// cache, be put into the buffer pool, and be used by other goroutines, which
	// leads to data race.
	b2 := dc.bufPool.Get().(*bytes.Buffer)
	b2.Reset()
	b2.Write(p)
	addFunc := func() {
		defer dc.bufPool.Put(b2)

		dc.fileMu.Lock()
		defer dc.fileMu.Unlock()

		// Check if cache exists.
		c := filepath.Join(dc.directory, blobHash[:2], blobHash)
		if _, err := os.Stat(c); err == nil {
			return
		}

		// Create cache file
		if err := os.MkdirAll(filepath.Dir(c), os.ModePerm); err != nil {
			fmt.Printf("Warning: Failed to Create blob cache directory %q: %v\n", c, err)
			return
		}
		f, err := os.Create(c)
		if err != nil {
			fmt.Printf("Warning: could not create a cache file at %q: %v\n", c, err)
			return
		}
		defer f.Close()

		want := b2.Len()
		if n, err := io.Copy(f, b2); err != nil || n != int64(want) {
			fmt.Printf("Warning: failed to write cache: %d(wrote)/%d(expected): %v\n",
				n, want, err)
		}
	}

	if dc.syncAdd {
		addFunc()
	} else {
		go addFunc()
	}
}

func NewMemoryCache() BlobCache {
	return &memoryCache{
		membuf: map[string]string{},
	}
}

// memoryCache is a cache implementation which backend is a memory.
type memoryCache struct {
	membuf map[string]string // read-only []byte map is more ideal but we don't have it in golang...
	mu     sync.Mutex
}

func (mc *memoryCache) Fetch(blobHash string, p []byte) (int, error) {
	mc.mu.Lock()
	defer mc.mu.Unlock()

	cache, ok := mc.membuf[blobHash]
	if !ok {
		return 0, fmt.Errorf("Missed cache: %q", blobHash)
	}
	return copy(p, cache), nil
}

func (mc *memoryCache) Add(blobHash string, p []byte) {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	mc.membuf[blobHash] = string(p)
}
