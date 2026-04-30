# Build command: AWS_PROFILE=staging packer build -var-file=./variables.auto.pkrvars.hcl github_agent.ubuntu.pkr.hcl

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
  "tfenv use 1.5.7"
]
