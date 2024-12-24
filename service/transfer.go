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
	"fmt"
	"sync"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/streaming"
	streamingproxy "github.com/containerd/containerd/v2/core/streaming/proxy"
	"github.com/containerd/containerd/v2/core/transfer/registry/auth"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/reference"
	"github.com/containerd/stargz-snapshotter/fs/source"
	"github.com/containerd/stargz-snapshotter/service/resolver"
)

func fromLabelsWithAuthStream(config ContainerdTransferKeychainConfig, cfg resolver.Config, credsFuncs ...resolver.Credential) source.GetSources {
	return func(labels map[string]string) ([]source.Source, error) {
		ctx := namespaces.WithNamespace(context.Background(), config.ContainerdNamespace)
		ctd, err := containerd.New(config.ContainerdAddress)
		if err != nil {
			return nil, fmt.Errorf("failed to connect to containerd")
		}
		credsFuncs := credsFuncs
		if f := credsFuncFromAuthStreamLabel(ctx, ctd, labels); f != nil {
			credsFuncs = append(credsFuncs, f)
		}
		return sourceFromCRILabels(resolver.RegistryHostsFromConfig(cfg, credsFuncs...))(labels)
	}
}

var streams = make(map[string]resolver.Credential)

var mu sync.Mutex

func credsFuncFromAuthStreamLabel(ctx context.Context, ctd *containerd.Client, labels map[string]string) resolver.Credential {
	mu.Lock()
	defer mu.Unlock()
	id, ok := labels["containerd.io/snapshot/creds-stream"]
	if !ok {
		return nil
	}
	if f, ok := streams[id]; ok {
		return f
	}

	sc := streamingproxy.NewStreamCreator(ctd.Conn())
	stream, err := sc.Create(ctx, id)
	if err != nil {
		return nil
	}

	cc := newCredCallback(stream)
	f := cc.getCredentials
	streams[id] = f
	return f
}

type credCallback struct {
	sync.Mutex
	cc auth.CredentialHelper
}

func newCredCallback(stream streaming.Stream) *credCallback {
	cc := auth.NewCredentialHelper(stream)
	return &credCallback{
		cc: cc,
	}
}

func (cc *credCallback) getCredentials(host string, refspec reference.Spec) (string, string, error) {
	cc.Lock()
	defer cc.Unlock()
	creds, err := cc.cc.GetCredentials(context.TODO(), refspec.String(), host)
	if err != nil {
		return "", "", err
	}
	return creds.Username, creds.Secret, nil
}
