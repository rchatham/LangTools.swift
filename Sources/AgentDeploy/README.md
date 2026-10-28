# AgentDeploy

`langtools-agent-deploy` runs [AgentRuntime](../AgentRuntime/README.md) workers wherever Docker runs. A **worker** is a `langtools-agent` container that takes jobs from a queue and delivers results by webhook or `status`. A **host** is any machine with Docker:

- **`local`**: the machine you're on, such as your Mac. Always available.
- **SSH hosts**: any server you can SSH into: a home server, a VM, a machine from any provider.
- **Provider hosts**: machines the tool creates for you. DigitalOcean (through `doctl`) is built in; `ComputeProvider` is the seam for others.

One host can run many workers. Docker restarts each one after a crash or reboot (`--restart unless-stopped`), so nothing else needs installing on the host.

## Isolation

- **Shared worker**: takes anyone's jobs. Use it for work that can share API keys and a queue.
- **Isolated worker** (`create --owner alice`): its own container, API keys and queue; it only takes jobs submitted with `--owner alice`. Other workers on the same host can't see its files, but they share the machine and Docker daemon.
- **Dedicated host** (`host add/create --owner alice`): a machine that only runs alice's workers. Use this when owners must not share a machine at all.

## Requirements

- Docker on every host, usable by the user you connect as (`docker version` must work without sudo).
- `ssh` for SSH and provider hosts. Host keys are pinned in `~/.config/langtools-agent/known_hosts` on first connection.
- `doctl`, authenticated with `doctl auth init`, to create DigitalOcean hosts. Set `DOCTL_CONTEXT` to pick an account.

```bash
swift build -c release --product langtools-agent-deploy
cp .build/release/langtools-agent-deploy /usr/local/bin/
```

## The image

Build it once per architecture you run on. A Mac with Apple silicon runs `linux/arm64`; most servers and all DigitalOcean droplets run `linux/amd64`.

```bash
# Local only
docker build -f Dockerfile.agent -t langtools-agent:dev .

# For remote hosts, push to a registry they can pull from
docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.agent \
  -t registry.digitalocean.com/my-registry/langtools-agent:1.0 --push .
```

A host that already has the image uses it without pulling, so a locally built `langtools-agent:dev` works for local workers with no registry. Pass `--pull` to always pull.

## Workers on your Mac

```bash
cat > ~/agent.env <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
LANGTOOLS_WEBHOOK_SECRET=whsec_...
EOF

langtools-agent-deploy create helper --image langtools-agent:dev --env-file ~/agent.env
langtools-agent-deploy submit helper spec.json --wait          # prints the result when done
```

The env file is `KEY=value` lines without quotes (Docker would keep them as part of the value). It's copied to `~/.config/langtools-agent/workers/<name>/env` on the host with mode 0600. Leave out `--env-file` for a worker that only uses providers with no key, such as a local Ollama. Inside the container, reach Ollama on your Mac at `http://host.docker.internal:11434` by setting the spec's `baseURL`.

## Workers on a server you can SSH into

```bash
langtools-agent-deploy host add homelab --ssh reid@192.168.1.20      # checks Docker is usable there
langtools-agent-deploy create research --host homelab --image ghcr.io/me/langtools-agent:1.0 --env-file ~/agent.env
```

`--port` and `--identity` set the SSH port and key. To prepare a fresh Ubuntu server, run the output of `langtools-agent-deploy host setup-script` on it as root. It installs Docker and turns on the firewall with only SSH allowed.

## Workers on DigitalOcean

```bash
langtools-agent-deploy host create do-1 --provider digitalocean --region sfo3 --size s-1vcpu-1gb
langtools-agent-deploy create shared --host do-1 --image registry.digitalocean.com/my-registry/langtools-agent:1.0 --env-file ~/agent.env

# A droplet for one owner
langtools-agent-deploy host create alice-1 --provider digitalocean --owner alice
langtools-agent-deploy create alice --host alice-1 --image ... --env-file ~/alice.env
```

`host create` makes the droplet (tagged `langtools-agent` and `langtools-agent-host:<name>`) with the setup script as user data, waits for it, and checks Docker. The user data holds no secrets, because it can be read from inside the droplet and DigitalOcean keeps it. Keys are copied over SSH, on stdin, so they never appear in a command line. For images in DigitalOcean Container Registry, workers on DigitalOcean hosts get read-only pull credentials automatically; elsewhere, pass `--registry-config` with a Docker `config.json`.

`host destroy do-1 --force` deletes the droplet and everything on it.

## Jobs

```bash
export LANGTOOLS_WEBHOOK_SECRET=whsec_...    # optional: signs this job's webhook instead of the worker's secret
langtools-agent-deploy submit shared spec.json --webhook https://example.com/agent-results --run-id job-42
langtools-agent-deploy submit alice spec.json --owner alice --wait --timeout 600
langtools-agent-deploy status shared job-42  # queued, running, or done with the result; exits 1 for an unknown run
```

The worker checks the spec against its own keys and tools at submit time, so a missing key or unknown tool fails right away instead of sitting in the queue. Results go to the webhook (see [webhook delivery](../AgentRuntime/README.md#delivering-results-to-a-webhook)) and stay readable with `status` for 7 days.

## Day-to-day

```bash
langtools-agent-deploy list                          # every worker on every host, with its state
langtools-agent-deploy host list
langtools-agent-deploy logs shared --lines 100
langtools-agent-deploy configure shared --env-file new.env      # rotate keys
langtools-agent-deploy configure shared --image ...:1.1 --pull  # upgrade
langtools-agent-deploy destroy shared --force        # add --keep-results to keep the queue volume
```

`configure` recreates the container and keeps its queue and results. Running jobs get five minutes to finish. A job cut off by a restart is started once more, then reported as `failed` instead of running a third time, since a tool it called may already have had side effects.

The registry of hosts and workers is `~/.config/langtools-agent/fleet.json`. `list` also finds worker containers the registry doesn't know about and adds them, so if the file is lost, add the hosts again and run `list`.

## What's on a host, per worker

| What | Name | Contents |
|------|------|----------|
| Container | `langtools-agent-<name>` | Read-only filesystem, all capabilities dropped, `no-new-privileges`, process limit, runs as uid 10001. Labelled `dev.langtools.agent.worker`, `.owner`, `.concurrency`. |
| Volume | `langtools-agent-<name>` | The queue and results, at `/spool`. |
| Directory | `~/.config/langtools-agent/workers/<name>/` | `env` (mode 0600) and, for private registries, `docker/config.json`. |

## From Swift

`AgentFleet` is the API the command is built on. Code can use it to hand work to a worker, for example to run a subagent in a container:

```swift
import AgentDeploy
import AgentRuntime

let fleet = AgentFleet(
    store: FleetStore(file: FleetStore.defaultDirectory(environment: ProcessInfo.processInfo.environment).appendingPathComponent("fleet.json")),
    runner: ProcessCommandRunner(),
    providers: [DigitalOceanCompute(runner: ProcessCommandRunner())]
)
let runID = try await fleet.submit(AgentJob(spec: spec), to: "helper")
let result = try await fleet.waitForResult(of: runID, on: "helper", timeout: 600)
print(result.output ?? result.error ?? "")
```

`AgentFleet` runs `docker`, `ssh` and `doctl` as processes, so it works in macOS and Linux command-line tools and servers, not in sandboxed iOS apps.

## Limits

- Workers that share a host share its Docker daemon. Anyone who can run `docker` there can read every worker's keys and jobs. For owners who must not share that, give each a dedicated host.
- DigitalOcean Container Registry credentials are read-only but don't expire, and they cover every repository in the registry.
- Results and queues live on each host; `destroy` without `--keep-results` deletes them.
