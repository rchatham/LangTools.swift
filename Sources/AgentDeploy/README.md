# AgentDeploy

`langtools-agent-deploy` runs [AgentRuntime](../AgentRuntime/README.md) workers on DigitalOcean. A worker is a droplet running the `langtools-agent` image as a long-lived service that takes jobs from a queue on its disk. You submit specs to it and get results back by webhook or with `status`.

- **Shared worker**: one droplet that takes anyone's jobs. Use it when everyone submitting is trusted to share API keys and a machine.
- **Isolated worker** (`--owner`): a droplet for one owner, with its own API keys, queue and results. It only accepts jobs submitted with that owner, so one owner's jobs, keys and tool side effects never touch another's.

The tool drives `doctl` for DigitalOcean and `ssh` for the droplet, so it uses your existing `doctl auth` and SSH keys and never handles an API token itself. Workers open no ports except SSH.

## Requirements

- `doctl`, authenticated with `doctl auth init`. Set `DOCTL_CONTEXT` to use a non-default account.
- `ssh` and `ssh-keygen`, and an SSH key on your DigitalOcean account (`doctl compute ssh-key list`). Set `LANGTOOLS_DEPLOY_SSH_IDENTITY` to use a key other than ssh's default.
- The `langtools-agent` image in a registry the droplet can pull from.

```bash
swift build -c release --product langtools-agent-deploy
cp .build/release/langtools-agent-deploy /usr/local/bin/
```

## 1. Publish the image

DigitalOcean Container Registry is the simplest choice, because the tool sets up pull credentials for it automatically:

```bash
doctl registry create my-registry        # once
doctl registry login
docker buildx build --platform linux/amd64 -f Dockerfile.agent \
  -t registry.digitalocean.com/my-registry/langtools-agent:1.0 --push .
```

Any other registry works if the image is public. Droplets are x86-64, so build for `linux/amd64` on Apple silicon.

## 2. Write the worker's env file

One `KEY=value` per line, without quotes (Docker would keep them as part of the value):

```bash
# worker.env
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
LANGTOOLS_WEBHOOK_SECRET=whsec_...
```

Each worker gets its own copy, so an isolated worker can use the owner's own provider keys.

## 3. Create a worker

```bash
# Shared
langtools-agent-deploy create shared \
  --image registry.digitalocean.com/my-registry/langtools-agent:1.0 \
  --env-file worker.env

# Isolated for one owner
langtools-agent-deploy create alice \
  --owner alice --env-file alice.env \
  --image registry.digitalocean.com/my-registry/langtools-agent:1.0 \
  --region sfo3 --size s-1vcpu-2gb --concurrency 4
```

`create` checks the name, image and env file before creating anything. Then it creates the droplet, waits for first-boot setup, uploads the env file over SSH, starts the service, and returns once the worker answers. This takes a few minutes, mostly installing Docker and pulling the image. Defaults are `nyc3`, `s-1vcpu-1gb` (about $6/month) and 2 concurrent jobs; agent runs mostly wait on the network, so a small droplet is enough.

## 4. Submit work

```bash
export LANGTOOLS_WEBHOOK_SECRET=whsec_...    # optional: signs this job's webhook instead of the worker's secret
langtools-agent-deploy submit shared spec.json --webhook https://example.com/agent-results --run-id job-42
# {"runID": "job-42", "state": "queued"}

langtools-agent-deploy submit alice spec.json --owner alice   # isolated workers need their owner

langtools-agent-deploy status shared job-42     # queued, running, or done with the result; exits 1 for an unknown run
```

The worker validates the spec against its own keys and tools when you submit, so a missing key or unknown tool fails right away rather than in the queue. The result goes to the webhook (see [webhook delivery](../AgentRuntime/README.md#delivering-results-to-a-webhook)) and stays readable with `status` for 7 days.

## Day-to-day

```bash
langtools-agent-deploy list                                 # name, owner, status, IP, region, size
langtools-agent-deploy logs shared --lines 100
langtools-agent-deploy configure shared --env-file new.env  # rotate keys
langtools-agent-deploy configure shared --image registry.digitalocean.com/my-registry/langtools-agent:1.1
langtools-agent-deploy destroy alice --force                # deletes the droplet, its queue and results
langtools-agent-deploy user-data                            # the first-boot script, to review before creating
```

`configure` restarts the service. Running jobs get five minutes to finish. A job cut off by a restart is started once more, then reported as `failed` instead of running a third time, since a tool it called may already have had side effects.

## What's on a worker

| Path | Contents |
|------|----------|
| `/etc/langtools-agent/env` | The env file: API keys and webhook secret. Mode 0600, root. |
| `/etc/langtools-agent/worker.conf` | `IMAGE` and `CONCURRENCY`. |
| `/etc/langtools-agent/docker/config.json` | Read-only registry credentials, for DigitalOcean Container Registry images. |
| `/var/lib/langtools-agent/` | The queue and results, owned by the container user. |

The `langtools-agent` systemd service runs the container with a read-only filesystem, all Linux capabilities dropped, `no-new-privileges`, and a process limit. The first-boot script installs Docker and the service and turns on the `ufw` firewall with only SSH allowed. It holds no secrets, because droplet user data can be read from inside the droplet and is kept by DigitalOcean. Keys are uploaded afterwards over SSH, on stdin, so they never appear in a command line. SSH host keys are trusted on first connection and pinned in `~/.config/langtools-agent/known_hosts`.

## Limits

- The registry credentials for DigitalOcean Container Registry are read-only but don't expire, and they cover every repository in the registry.
- Anyone with root SSH access to a worker can read its keys and every job. An isolated worker is the boundary between owners; jobs on a shared worker can see each other's files.
- Results and the queue live on the droplet's disk; `destroy` deletes them.

## Other providers

`ComputeProvider` is the seam for other clouds: create, list and delete machines, and supply registry credentials. `DigitalOceanCompute` is the only implementation. The worker setup itself (first-boot script, systemd unit, SSH commands) assumes a recent Ubuntu machine with root SSH, not anything DigitalOcean-specific.
