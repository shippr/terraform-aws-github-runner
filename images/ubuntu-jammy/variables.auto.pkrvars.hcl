
# Build command: packer build -var-file=./variables.auto.pkrvars.hcl github_agent.ubuntu.pkr.hcl

custom_shell_commands = [
  # https://github.com/nodesource/distributions?tab=readme-ov-file#installation-instructions
  <<EOT
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

  NODE_MAJOR=22
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

  sudo apt-get update
  sudo apt-get install nodejs -y
  EOT
  ,

  # Install Sops
  "wget https://github.com/mozilla/sops/releases/download/v3.8.1/sops_3.8.1_amd64.deb",
  "sudo apt-get install ./sops_3.8.1_amd64.deb",

  # Install Terraform
  "git clone https://github.com/tfutils/tfenv.git ~/.tfenv",
  "sudo ln -s ~/.tfenv/bin/* /usr/local/bin",
  "tfenv install 1.4.0",
  "tfenv use 1.4.0"
]
