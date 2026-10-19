# Kubernetes Labs

Free, hands-on labs for **Kubernetes for AI infrastructure**, from Cloud Brewery Academy and the
*Kubernetes Labs and Concepts* newsletter. One concept per lab: break it, fix it, then show the evidence.

Independent course. Not affiliated with or endorsed by NVIDIA.

## Two ways to run the labs

| Mode | Runs on | Needs |
|---|---|---|
| **Laptop (default)** | your machine | Docker (Docker Desktop or Colima), kind, kubectl; Helm from Lab 2 |
| **Cloud GPU (optional parts)** | one GPU instance in AWS that terminates itself after 55 minutes | an AWS account, GPU quota and a budget alarm; marked clearly in the lab that needs it |

Most labs run on a laptop. When a concept only shows up on real GPUs, that lab says so at the top.

## Labs

| Lab | What you'll do | Mode |
|---|---|---|
| [Lab 1: Schedule a GPU workload without a GPU](lab01-gpu-scheduling/) | Make a Pending GPU pod schedule, keep other pods off GPU nodes, cap a team's GPUs, rehearse a GPU fleet with KWOK | Laptop |
| [Lab 2: Share one GPU between pods with DRA](lab02-gpu-sharing/) | Share one (mock) GPU through a ResourceClaim, take slices of it, then see time-slicing vs MPS on a real GPU | Laptop; optional AWS GPU |

## Where to start

Read [lab01-gpu-scheduling/README.md](lab01-gpu-scheduling/README.md) and follow the steps, or run
`lab01-gpu-scheduling/scripts/run-lab.sh` to do them all and save the evidence.

## Licence

Code is licensed under Apache-2.0; lab guides and other written and visual material under CC BY 4.0. Third-party
material keeps its own terms. See [LICENSING.md](LICENSING.md) for what applies where.
