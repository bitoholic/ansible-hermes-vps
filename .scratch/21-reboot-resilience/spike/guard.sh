# Sourced by the spike scripts. Refuses to run anywhere but INSIDE the disposable podman container.
# The design relies on the container's own network namespace, so a mistaken run on a workstation or a
# host must be impossible, not merely discouraged (an env var alone is not a guard).
spike_guard() {
  [[ "${SPIKE_IN_DISPOSABLE_CONTAINER:-}" == "1" ]] || { echo "refusing: SPIKE_IN_DISPOSABLE_CONTAINER!=1" >&2; exit 2; }
  # podman writes /run/.containerenv into every container it starts; a host never has it.
  [[ -f /run/.containerenv ]] && grep -q 'engine="podman' /run/.containerenv \
    || { echo "refusing: not inside a podman container (/run/.containerenv missing)" >&2; exit 2; }
  # ...and specifically THIS harness's own container: run.sh names it (a stray podman container that shares the
  # host network namespace would otherwise pass the checks above).
  grep -q 'name="hermes-spike"' /run/.containerenv \
    || { echo "refusing: not the hermes-spike container (/run/.containerenv name mismatch)" >&2; exit 2; }
  # A private network namespace exposes only lo + one uplink; a host (or --network=host) shows more.
  local n; n=$(ls /sys/class/net | grep -vc '^lo$' || true)
  (( n <= 2 )) || { echo "refusing: $n network interfaces visible — looks like the host network namespace" >&2; exit 2; }
}
