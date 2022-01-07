# Set of scripts to measure pull latency on GKE with IPFS

Measures time to take to pull image from container registry or IPFS seeder to kubernetes cluster.

```
  source of images
+-----------------+                              +-------------+
| registry/seeder | <-- bandwidth limitation --> | GKE cluster |
+-----------------+                              +-------------+
                    pull via IPFS or registry API
```

## Prerequisites

- GKE cluster: at least 20 nodes
- registry/seeder node: 1 node
  - used as container registry and IPFS node (seeder of image)
  - make it accessible from all GKE nodes and pods
- Make sure all GKE nodes and registry/seeder node are accessible with ssh

## Run

```
export PROJECT="your-project"
export ZONE="your-zone"
export REGISTRY_NODE="your-registry-seeder-instance"
export REGISTRY_NODE_IP="ip-of-your-registry-seeder-instance"
export RESULT_DIR="~/dir/to/store/result"
mkdir -p $RESULT_DIR
./run.sh 2>&1 | tee $RESULT_DIR/log
```
