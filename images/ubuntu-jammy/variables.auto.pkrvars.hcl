# Build command: AWS_PROFILE=staging packer build -var-file=./variables.auto.pkrvars.hcl github_agent.ubuntu.pkr.hcl
#
# The build also needs ./workspace-manifests.tgz (the package manifests of
# shippr/shippr). `packer-build-ami.yml` downloads it; from a laptop:
#   AWS_PROFILE=staging aws s3 cp s3://shippr-github-cache-bucket/runner-ami/workspace-manifests.tgz .

# The builder's root volume becomes the AMI's snapshot, so it must hold the
# service images, the pnpm store and Chromium on top of the base system. The
# launch templates in shippr/shippr `infra/github-ci/runner.tf` give 30 GB and
# can grow it, never shrink it: keep this at or under 30.
root_volume_size_gb = 20

# The pnpm install and Playwright's apt step dominate the build; t3.medium's
# burst credits run out halfway through.
instance_type = "m7a.large"

custom_shell_commands = [
  # Install Node 24
  <<EOT
  sudo apt-get update
  sudo apt-get install -y curl
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo apt-get install -y nodejs
  EOT
  ,

  # Install Sops
  "wget https://github.com/mozilla/sops/releases/download/v3.8.1/sops_3.8.1_amd64.deb",
  "sudo apt-get install ./sops_3.8.1_amd64.deb",

  # Install Terraform
  "git clone https://github.com/tfutils/tfenv.git ~/.tfenv",
  "sudo ln -s ~/.tfenv/bin/* /usr/local/bin",
  "tfenv install 1.5.7",
  "tfenv use 1.5.7",

  # The service containers of shippr/shippr `.github/workflows/test.yml`. A
  # runner otherwise pulls them at the start of every job ("Initialize
  # containers", ~45 s). Tags must match test.yml; a tag bumped there without a
  # rebuild here just pulls as before. `sudo`: the docker group added to
  # `ubuntu` above only applies to a new login.
  "sudo docker pull public.ecr.aws/m1g6j3z8/shippr/postgres:17",
  "sudo docker pull public.ecr.aws/m1g6j3z8/shippr/valkey:9.1",
  "sudo docker pull public.ecr.aws/localstack/localstack:4",
  "sudo docker pull public.ecr.aws/m1g6j3z8/shippr/stripe-mock:v0.202.0",

  # The pnpm of shippr/shippr's `packageManager`. The runners run as root
  # (`runner_as_root`), so it goes in root's corepack cache (sudo resets HOME
  # on Ubuntu). Node 24 still bundles corepack; it was dropped in Node 25.
  "sudo COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare pnpm@11.7.0 --activate",
]
