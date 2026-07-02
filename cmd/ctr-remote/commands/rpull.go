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

package commands

import (
	"context"
	"fmt"
	"os"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/cmd/ctr/commands"
	"github.com/containerd/containerd/v2/cmd/ctr/commands/content"
	ctrimages "github.com/containerd/containerd/v2/cmd/ctr/commands/images"
	"github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/containerd/v2/core/transfer"
	"github.com/containerd/containerd/v2/core/transfer/image"
	"github.com/containerd/containerd/v2/core/transfer/registry"
	ctdsnapshotters "github.com/containerd/containerd/v2/pkg/snapshotters"
	"github.com/containerd/log"
	"github.com/containerd/platforms"
	fsconfig "github.com/containerd/stargz-snapshotter/fs/config"
	"github.com/containerd/stargz-snapshotter/fs/source"
	"github.com/containerd/stargz-snapshotter/ipfs"
	// "github.com/containerd/stargz-snapshotter/service/verifier"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/urfave/cli/v3"
)

const (
	remoteSnapshotterName = "stargz"
	skipContentVerifyOpt  = "skip-content-verify"
)

// RpullCommand is a subcommand to pull an image from a registry leveraging stargz snapshotter
var RpullCommand = &cli.Command{
	Name:      "rpull",
	Usage:     "pull an image from a registry leveraging stargz snapshotter",
	ArgsUsage: "[flags] <ref>",
	Description: `Fetch and prepare an image for use in containerd leveraging stargz snapshotter.

After pulling an image, it should be ready to use the same reference in a run
command. 
`,
	Flags: append(append(commands.RegistryFlags, commands.LabelFlag,
		&cli.BoolFlag{
			Name:  skipContentVerifyOpt,
			Usage: "Skip content verification for layers contained in this image.",
		},
		&cli.BoolFlag{
			Name:  "ipfs",
			Usage: "Pull image from IPFS. Specify an IPFS CID as a reference. (experimental)",
		},
		&cli.BoolFlag{
			Name:  "use-containerd-labels",
			Usage: "Use labels defined in containerd project",
		},
		&cli.BoolFlag{
			Name:  "local",
			Usage: "Fetch content from local client rather than using transfer service",
			Value: true,
		},
	), commands.SnapshotterFlags...),
	Action: func(ctx context.Context, context *cli.Command) error {
		var (
			ref    = context.Args().First()
			config = &rPullConfig{}
		)
		if ref == "" {
			return fmt.Errorf("please provide an image reference to pull")
		}

		client, ctx, cancel, err := commands.NewClient(ctx, context)
		if err != nil {
			return err
		}
		defer cancel()

		if !context.Bool("local") {
			return transferPull(ctx, client, ref, context)
		}

		ctx, done, err := client.WithLease(ctx)
		if err != nil {
			return err
		}
		defer done(ctx)

		fc, err := content.NewFetchConfig(ctx, context)
		if err != nil {
			return err
		}
		config.FetchConfig = fc
		config.containerdLabels = context.Bool("use-containerd-labels")

		if context.Bool(skipContentVerifyOpt) {
			config.skipVerify = true
		}

		if context.Bool("ipfs") {
			r, err := ipfs.NewResolver(ipfs.ResolverOptions{
				Scheme: "ipfs",
			})
			if err != nil {
				return err
			}
			config.Resolver = r
		}
		config.snapshotter = remoteSnapshotterName
		if sn := context.String("snapshotter"); sn != "" {
			config.snapshotter = sn
		}

		return pull(ctx, client, ref, config)
	},
}

type rPullConfig struct {
	*content.FetchConfig
	skipVerify       bool
	snapshotter      string
	containerdLabels bool
}

func pull(ctx context.Context, client *containerd.Client, ref string, config *rPullConfig) error {
	pCtx := ctx
	h := images.HandlerFunc(func(ctx context.Context, desc ocispec.Descriptor) ([]ocispec.Descriptor, error) {
		if desc.MediaType != images.MediaTypeDockerSchema1Manifest {
			fmt.Printf("fetching %v... %v\n", desc.Digest.String()[:15], desc.MediaType)
		}
		return nil, nil
	})

	var snOpts []snapshots.Opt
	if config.skipVerify {
		log.G(pCtx).WithField("image", ref).Warn("content verification disabled")
		snOpts = append(snOpts, snapshots.WithLabels(map[string]string{
			fsconfig.TargetSkipVerifyLabel: "true",
		}))
	}

	var labelHandler func(h images.Handler) images.Handler
	prefetchSize := int64(10 * 1024 * 1024)
	if config.containerdLabels {
		labelHandler = source.AppendExtraLabelsHandler(prefetchSize, ctdsnapshotters.AppendInfoHandlerWrapper(ref))
	} else {
		labelHandler = source.AppendDefaultLabelsHandlerWrapper(ref, prefetchSize)
	}

	log.G(pCtx).WithField("image", ref).Debug("fetching")
	labels := commands.LabelArgs(config.Labels)
	if _, err := client.Pull(pCtx, ref, []containerd.RemoteOpt{
		containerd.WithPullLabels(labels),
		containerd.WithResolver(config.Resolver),
		containerd.WithImageHandler(h),
		containerd.WithPullUnpack,
		containerd.WithPullSnapshotter(config.snapshotter, snOpts...),
		containerd.WithImageHandlerWrapper(labelHandler),
	}...); err != nil {
		return err
	}

	return nil
}

// transferPull pulls the image using the transfer service. Labels for the remote
// snapshotter are appended by containerd so the snapshotter needs to enable
// "enable_remote_snapshot_annotations" export and to be configured in the unpack
// configuration of the transfer service.
func transferPull(ctx context.Context, client *containerd.Client, ref string, cmd *cli.Command) error {
	unsupportedFlags := []string{skipContentVerifyOpt, "ipfs", "use-containerd-labels",
		"max-concurrent-downloads", "skip-verify", "tlscacert", "tlscert", "tlskey", // RegistryFlags
	}
	for _, s := range unsupportedFlags {
		if cmd.IsSet(s) {
			return fmt.Errorf("\"--%s\" requires \"--local\" flag", s)
		}
	}

	ch, err := commands.NewStaticCredentials(ctx, cmd, ref)
	if err != nil {
		return err
	}

	snapshotter := remoteSnapshotterName
	if sn := cmd.String("snapshotter"); sn != "" {
		snapshotter = sn
	}
	sopts := []image.StoreOpt{
		image.WithPlatforms(platforms.DefaultSpec()),
		image.WithUnpack(platforms.DefaultSpec(), snapshotter),
		image.WithAllMetadata,
	}
	if labels := cmd.StringSlice("label"); len(labels) > 0 {
		sopts = append(sopts, image.WithImageLabels(commands.LabelArgs(labels)))
	}

	opts := []registry.Opt{
		registry.WithCredentials(ch),
		registry.WithHostDir(cmd.String("hosts-dir")),
	}
	if cmd.Bool("plain-http") {
		opts = append(opts, registry.WithDefaultScheme("http"))
	}
	logStream := log.G(ctx).Writer()
	if cmd.Bool("http-dump") {
		opts = append(opts, registry.WithHTTPDebug(), registry.WithClientStream(logStream))
	}
	if cmd.Bool("http-trace") {
		opts = append(opts, registry.WithHTTPTrace(), registry.WithClientStream(logStream))
	}
	reg, err := registry.NewOCIRegistry(ctx, ref, opts...)
	if err != nil {
		return err
	}
	is := image.NewStore(ref, sopts...)

	pf, done := ctrimages.ProgressHandler(ctx, os.Stdout)
	defer done()

	return client.Transfer(ctx, reg, is, transfer.WithProgress(pf))
}
