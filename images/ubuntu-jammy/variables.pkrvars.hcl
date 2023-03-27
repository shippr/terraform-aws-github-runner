custom_shell_commands = [
  # Install node
  "curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt-get install -y nodejs",

  # Install Sops
  "wget https://github.com/mozilla/sops/releases/download/v3.7.3/sops_3.7.3_amd64.deb",
  "apt-get install ./sops_3.7.3_amd64.deb",

  # Install Terraform
  "git clone https://github.com/tfutils/tfenv.git ~/.tfenv",
  "ln -s ~/.tfenv/bin/* /usr/local/bin",
  "tfenv install 1.4.0",
  "tfenv use 1.4.0"
]
