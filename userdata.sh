#!/bin/bash
set -euxo pipefail

# ── System updates ────────────────────────────────────────────────────────────
dnf update -y

# ── Essential tools ───────────────────────────────────────────────────────────
dnf install -y \
  amazon-cloudwatch-agent \
  amazon-ssm-agent \
  curl \
  git \
  htop \
  jq \
  unzip \
  wget

# ── SSM Agent ─────────────────────────────────────────────────────────────────
systemctl enable amazon-ssm-agent
systemctl start  amazon-ssm-agent

# ── CloudWatch Agent basic config ─────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF'
{
  "agent": { "metrics_collection_interval": 60, "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log" },
  "metrics": {
    "namespace": "CWAgent",
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    },
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/messages",   "log_group_name": "/${project_name}/${environment}/messages" },
          { "file_path": "/var/log/cloud-init*", "log_group_name": "/${project_name}/${environment}/cloud-init" }
        ]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent
systemctl start  amazon-cloudwatch-agent

# ── Hostname ──────────────────────────────────────────────────────────────────
hostnamectl set-hostname "${project_name}-${environment}"

echo "User data script completed successfully."
