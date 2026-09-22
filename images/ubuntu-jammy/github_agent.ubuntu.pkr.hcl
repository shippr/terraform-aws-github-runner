packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "runner_version" {
  description = "The version (no v prefix) of the runner software to install https://github.com/actions/runner/releases. The latest release will be fetched from GitHub if not provided."
  default     = null
}

variable "region" {
  description = "The region to build the image in"
  type        = string
  default     = "eu-west-1"
}

variable "security_group_id" {
  description = "The ID of the security group Packer will associate with the builder to enable access"
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "If using VPC, the ID of the subnet, such as subnet-12345def, where Packer will launch the EC2 instance. This field is required if you are using an non-default VPC"
  type        = string
  default     = null
}

variable "associate_public_ip_address" {
  description = "If using a non-default VPC, there is no public IP address assigned to the EC2 instance. If you specified a public subnet, you probably want to set this to true. Otherwise the EC2 instance won't have access to the internet"
  type        = string
  default     = null
}

variable "instance_type" {
  description = "The instance type Packer will use for the builder"
  type        = string
  default     = "t3.medium"
}

variable "iam_instance_profile" {
  description = "IAM instance profile Packer will use for the builder. An empty string (default) means no profile will be assigned."
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  type    = number
  default = 8
}

variable "ebs_delete_on_termination" {
  description = "Indicates whether the EBS volume is deleted on instance termination."
  type        = bool
  default     = true
}

variable "global_tags" {
  description = "Tags to apply to everything"
  type        = map(string)
  default     = {}
}

variable "ami_tags" {
  description = "Tags to apply to the AMI"
  type        = map(string)
  default     = {}
}

variable "snapshot_tags" {
  description = "Tags to apply to the snapshot"
  type        = map(string)
  default     = {}
}

variable "custom_shell_commands" {
  description = "Additional commands to run on the EC2 instance, to customize the instance, like installing packages"
  type        = list(string)
  default     = []
}

variable "temporary_security_group_source_public_ip" {
  description = "When enabled, use public IP of the host (obtained from https://checkip.amazonaws.com) as CIDR block to be authorized access to the instance, when packer is creating a temporary security group. Note: If you specify `security_group_id` then this input is ignored."
  type        = bool
  default     = false
}

variable "workspace_manifests_path" {
  description = "Tarball of shippr/shippr's package manifests (every package.json, pnpm-lock.yaml, pnpm-workspace.yaml, .npmrc, patches/), uploaded by its `upload-runner-ami-inputs.yml`. Installed once at build time to warm the pnpm store."
  type        = string
  default     = "./workspace-manifests.tgz"
}

data "http" github_runner_release_json {
  url = "https://api.github.com/repos/actions/runner/releases/latest"
  request_headers = {
    Accept = "application/vnd.github+json"
    X-GitHub-Api-Version : "2022-11-28"
  }
}

locals {
  runner_version = coalesce(var.runner_version, trimprefix(jsondecode(data.http.github_runner_release_json.body).tag_name, "v"))
}

source "amazon-ebs" "githubrunner" {
  ami_name                                  = "github-runner-ubuntu-jammy-amd64-${formatdate("YYYYMMDDhhmm", timestamp())}"
  instance_type                             = var.instance_type
  iam_instance_profile                      = var.iam_instance_profile
  region                                    = var.region
  security_group_id                         = var.security_group_id
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = var.associate_public_ip_address
  temporary_security_group_source_public_ip = var.temporary_security_group_source_public_ip

  source_ami_filter {
    filters = {
      name                = "*ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"
  tags = merge(
    var.global_tags,
    var.ami_tags,
    {
      OS_Version    = "ubuntu-jammy"
      Release       = "Latest"
      Base_AMI_Name = "{{ .SourceAMIName }}"
  })
  snapshot_tags = merge(
    var.global_tags,
    var.snapshot_tags,
  )

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = "${var.root_volume_size_gb}"
    volume_type           = "gp3"
    delete_on_termination = "${var.ebs_delete_on_termination}"
  }
}

build {
  name = "githubactions-runner"
  sources = [
    "source.amazon-ebs.githubrunner"
  ]
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = concat([
      "sudo cloud-init status --wait",
      "sudo apt-get -y update",
      "sudo apt-get -y install ca-certificates curl gnupg lsb-release",
      "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get -y update",
      "sudo apt-get -y install docker-ce docker-ce-cli containerd.io jq git unzip",
      "sudo systemctl enable containerd.service",
      "sudo service docker start",
      "sudo usermod -a -G docker ubuntu",
      "sudo curl -f https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o amazon-cloudwatch-agent.deb",
      "sudo dpkg -i amazon-cloudwatch-agent.deb",
      "sudo systemctl restart amazon-cloudwatch-agent",
      "sudo curl -f https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "unzip awscliv2.zip",
      "sudo ./aws/install",
    ], var.custom_shell_commands)
  }

  # Warm pnpm store, pnpm metadata cache and Chromium for shippr/shippr's CI.
  # The workspace is installed once in a scratch directory and thrown away;
  # what stays in the AMI is the content-addressed store (plus the side-effects
  # cache of the packages that build), which a CI job then links from with
  # `--prefer-offline` instead of downloading. Everything lands under /opt as
  # root: the runners run as root (`runner_as_root` in infra/github-ci).
  #
  # `CI=1` skips the root `prepare` script (husky needs a .git, and there is
  # none here). Dependency build scripts run only for the `allowBuilds` list
  # of shippr/shippr's pnpm-workspace.yaml; the two native ones there without
  # a prebuild (unix-dgram, cpu-features) are optional dependencies, so a
  # missing compiler only skips them.
  # `.npmrc` holds no registry token: every package is public.
  provisioner "file" {
    source      = var.workspace_manifests_path
    destination = "/tmp/workspace-manifests.tgz"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "CI=1",
      "COREPACK_ENABLE_DOWNLOAD_PROMPT=0",
      # Also for `pnpm exec` below: pnpm 11 checks node_modules before running
      # a binary, and one installed from another store counts as stale, so it
      # would purge and reinstall into the default store under /root.
      "pnpm_config_store_dir=/opt/pnpm-store",
      "pnpm_config_cache_dir=/opt/pnpm-cache",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
    inline_shebang  = "/bin/bash -e"
    inline = [
      "set -euxo pipefail",
      "scratch=$(mktemp -d /tmp/workspace.XXXXXX)",
      "tar xzf /tmp/workspace-manifests.tgz -C \"$scratch\"",
      "cd \"$scratch\"",
      "corepack pnpm install --frozen-lockfile --store-dir /opt/pnpm-store --cache-dir /opt/pnpm-cache",
      "PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright corepack pnpm exec playwright install --with-deps chromium",
      "cd /",
      "rm -rf \"$scratch\" /tmp/workspace-manifests.tgz",
      "du -sh /opt/pnpm-store /opt/pnpm-cache /opt/ms-playwright",
      "df -h /",
    ]
  }

  provisioner "file" {
    content = templatefile("../install-runner.sh", {
      install_runner = templatefile("../../modules/runners/templates/install-runner.sh", {
        ARM_PATCH                       = ""
        S3_LOCATION_RUNNER_DISTRIBUTION = ""
        RUNNER_ARCHITECTURE             = "x64"
      })
    })
    destination = "/tmp/install-runner.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${local.runner_version}/actions-runner-linux-x64-${local.runner_version}.tar.gz"
    ]
    inline = [
      "sudo chmod +x /tmp/install-runner.sh",
      "echo ubuntu | tee -a /tmp/install-user.txt",
      "sudo RUNNER_ARCHITECTURE=x64 RUNNER_TARBALL_URL=$RUNNER_TARBALL_URL /tmp/install-runner.sh",
      "echo ImageOS=ubuntu22 | tee -a /opt/actions-runner/.env"
    ]
  }

  provisioner "file" {
    content = templatefile("../start-runner.sh", {
      start_runner = templatefile("../../modules/runners/templates/start-runner.sh", { metadata_tags = "enabled" })
    })
    destination = "/tmp/start-runner.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/start-runner.sh /var/lib/cloud/scripts/per-boot/start-runner.sh",
      "sudo chmod +x /var/lib/cloud/scripts/per-boot/start-runner.sh",
    ]
  }

  # Read the AMI's hot files once at boot, in the background. A volume made
  # from a snapshot fetches each block from S3 on its first read, which cost
  # about 25 s of boot (the AWS CLI, the runner, the CloudWatch agent all
  # load from cold disk) and about 25 s of `pnpm install` per job. Reading
  # ahead turns those into local reads by the time they are needed.
  #
  # Order is by when a job needs a file: the AWS CLI (start-runner.sh, about
  # 18 s after the kernel), the runner and the agent (about 34 s), the
  # runner's node for JavaScript actions (checkout), then the pnpm store
  # (`install-node-modules`, about 40 s after the runner starts). In the
  # store the index comes first, then every inode (a hardlink import needs
  # only those), then the file contents, which the tests read through the
  # hardlinks. Contents are read in parallel: lazy loading is bound by
  # latency per block, not by bandwidth.
  #
  # `Type=simple` and no `DefaultDependencies`: the unit starts as soon as
  # the root filesystem is up, and nothing waits for it (a oneshot wanted by
  # multi-user.target would hold back cloud-final and so the runner). The
  # pnpm cache is left out: a frozen-lockfile install does not read it.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Path }}"
    inline_shebang  = "/bin/bash -e"
    inline = [
      <<-EOT
      cat > /usr/local/sbin/prewarm-disk <<'EOF'
      #!/bin/bash
      set -u
      log() { echo "prewarm-disk: $* after $(cut -d' ' -f1 /proc/uptime) s"; }
      read_tree() {
        if [ -e "$1" ]; then
          find "$1" -type f -print0 | xargs -0 -r -P "$2" -n 64 cat > /dev/null 2>&1
          log "read $1"
        fi
      }
      log "start"
      read_tree /usr/local/aws-cli 4
      read_tree /opt/actions-runner/bin 4
      read_tree /opt/aws/amazon-cloudwatch-agent/bin 4
      read_tree /opt/actions-runner/externals 4
      for store in /opt/pnpm-store/*/; do
        for index in "$store"index.db* "$store"index; do
          read_tree "$index" 8
        done
        find "$store" -printf '%s\n' > /dev/null
        log "stat $store"
      done
      # Not the store's file contents: reading all 4 GB in parallel competed
      # with `pnpm install` for the volume's throughput, and install went from
      # 50 s to 80 s (shippr run 35676213803, 2026-09-22).
      log "done"
      EOF
      chmod 755 /usr/local/sbin/prewarm-disk
      cat > /etc/systemd/system/prewarm-disk.service <<'EOF'
      [Unit]
      Description=Read the AMI's hot files ahead of the runner and its first job
      DefaultDependencies=no
      After=local-fs.target
      Conflicts=shutdown.target
      Before=shutdown.target

      [Service]
      Type=simple
      ExecStart=/usr/local/sbin/prewarm-disk
      Nice=10
      IOSchedulingClass=best-effort
      IOSchedulingPriority=7
      StandardOutput=journal+console

      [Install]
      WantedBy=multi-user.target
      EOF
      systemctl enable prewarm-disk.service
      EOT
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
