"""Shared inventory for publishable OCI images.

`repository` is the image NAME only. The registry host and project come from
stamped workspace status (STABLE_OCI_REGISTRY / STABLE_OCI_PROJECT, set from
OCI_REGISTRY / OCI_PROJECT by scripts/workspace_status.sh), so one variable
moves every image. See docs/GHCR_PUBLISHING.md.
"""

PUBLISHABLE_IMAGES = [
    {"image": "core_elx_image_amd64", "repository": "serviceradar-core-elx"},
    {"image": "agent_image_amd64", "push_image": "agent_image_multiarch", "repository": "serviceradar-agent"},
    {"image": "trivy_sidecar_image_amd64", "push_image": "trivy_sidecar_image_multiarch", "repository": "serviceradar-trivy-sidecar"},
    {"image": "k8s_inventory_image_amd64", "push_image": "k8s_inventory_image_multiarch", "repository": "serviceradar-k8s-inventory"},
    {"image": "datasvc_image_amd64", "push_image": "datasvc_image_multiarch", "repository": "serviceradar-datasvc"},
    {"image": "log_collector_image_amd64", "push_image": "log_collector_image_multiarch", "repository": "serviceradar-log-collector"},
    {"image": "trapd_image_amd64", "push_image": "trapd_image_multiarch", "repository": "serviceradar-trapd"},
    {"image": "dgraph_migrate_image_amd64", "push_image": "dgraph_migrate_image_multiarch", "repository": "serviceradar-dgraph-migrate"},
    {"image": "flow_collector_image_amd64", "push_image": "flow_collector_image_multiarch", "repository": "serviceradar-flow-collector"},
    {"image": "bmp_collector_image_amd64", "push_image": "bmp_collector_image_multiarch", "repository": "arancini"},
    {"image": "rperf_client_image_amd64", "push_image": "rperf_client_image_multiarch", "repository": "serviceradar-rperf-client"},
    {"image": "agent_gateway_image_amd64", "push_image": "agent_gateway_image_multiarch", "repository": "serviceradar-agent-gateway"},
    {"image": "faker_image_amd64", "push_image": "faker_image_multiarch", "repository": "serviceradar-faker"},
    {"image": "config_updater_image_amd64", "push_image": "config_updater_image_multiarch", "repository": "serviceradar-config-updater"},
    {"image": "web_ng_image_amd64", "repository": "serviceradar-web-ng"},
    {"image": "cert_generator_image_amd64", "push_image": "cert_generator_image_multiarch", "repository": "serviceradar-cert-generator"},
    {"image": "tools_image_amd64", "push_image": "tools_image_multiarch", "repository": "serviceradar-tools"},
    {
        "image": "cnpg_image_amd64",
        "repository": "serviceradar-cnpg",
        "static_tags": ["18.4.0-sr4"],
    },
    {
        "image": "cnpg_analytics_image_amd64",
        "repository": "serviceradar-cnpg-analytics",
        "static_tags": ["18-pgduckdb-1.1.1-sr1"],
    },
]

def publishable_image_labels():
    """Return local labels for the canonical build artifact of each publishable image."""

    labels = []
    for target in PUBLISHABLE_IMAGES:
        labels.append(":{}".format(target.get("push_image", target["image"])))
    return labels
