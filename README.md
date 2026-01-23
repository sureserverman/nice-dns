<h1 align="center">
  <a href="https://github.com/sureserverman/nice-dns">
    <!-- Please provide path to your logo here -->
    <img src="docs/images/logo.svg" alt="Logo" width="100" height="100">
  </a>
</h1>

<div align="center">
  nice-dns
  <br />
  <a href="#about"><strong>Explore the screenshots »</strong></a>
  <br />
  <br />
  <a href="https://github.com/sureserverman/nice-dns/issues/new?assignees=&labels=bug&template=01_BUG_REPORT.md&title=bug%3A+">Report a Bug</a>
  ·
  <a href="https://github.com/sureserverman/nice-dns/issues/new?assignees=&labels=enhancement&template=02_FEATURE_REQUEST.md&title=feat%3A+">Request a Feature</a>
  .
  <a href="https://github.com/sureserverman/nice-dns/issues/new?assignees=&labels=question&template=04_SUPPORT_QUESTION.md&title=support%3A+">Ask a Question</a>
</div>

<div align="center">
<br />

[![Project license](https://img.shields.io/github/license/sureserverman/nice-dns.svg?style=flat-square)](LICENSE)

[![Pull Requests welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg?style=flat-square)](https://github.com/sureserverman/nice-dns/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
[![code with love by sureserverman](https://img.shields.io/badge/%3C%2F%3E%20with%20%E2%99%A5%20by-sureserverman-ff1414.svg?style=flat-square)](https://github.com/sureserverman)

</div>

<details open="open">
<summary>Table of Contents</summary>

- [About](#about)
- [Usage](#usage)
- [Roadmap](#roadmap)
- [Project assistance](#project-assistance)
- [Authors & contributors](#authors--contributors)
- [Security](#security)
- [License](#license)

</details>

---

## About

> This is docker-compose file and all necessary files to build multi-container application with pi-hole, unbound and socat with tor
> chained together to provide DNS stripped of excessive advertising, trackers, malware and upstreaming your DNS requests, encrypted with tls to 
> CloudFlare's hidden .onion DNS resolver

## Usage

### Quadlet-based Installation (Recommended)

This project uses **Podman Quadlets** for native systemd integration. Quadlets provide:
- Automatic container lifecycle management through systemd
- Native service dependencies and ordering
- Proper integration with system boot/shutdown
- Better resource management and logging

> To install on Ubuntu/Debian with one-line command:\
> `bash <(curl -Ls https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh)`

Run this command **without** `sudo`. The script uses `sudo` internally when
needed and must be executed as your regular user so that rootless Podman and
user-mode systemd work correctly.

The installation will:
1. Install Podman and required dependencies
2. Build container images for unbound and pi-hole
3. Pull the tor-socat image
4. Install quadlet files to `~/.config/containers/systemd/`
5. Enable systemd services for automatic startup
6. Configure system DNS to use 127.0.0.1:53

After installation, manage services with:
```bash
# Check status
systemctl --user status pi-hole.service

# View logs
journalctl --user -u pi-hole.service -f

# Restart a service
systemctl --user restart pi-hole.service

# Stop all services
systemctl --user stop tor-socat.service unbound.service pi-hole.service
```

### Docker Compose Installation (Alternative)

> For traditional Docker/Podman Compose deployment:\
> `git clone https://github.com/sureserverman/nice-dns.git`\
> `cd nice-dns`

Then choose your deployment method:

- **Standard deployment**:\
  `sudo docker compose up -d`
> 


## Roadmap

See the [open issues](https://github.com/sureserverman/nice-dns/issues) for a list of proposed features (and known issues).

- [Top Feature Requests](https://github.com/sureserverman/nice-dns/issues?q=label%3Aenhancement+is%3Aopen+sort%3Areactions-%2B1-desc) (Add your votes using the 👍 reaction)
- [Top Bugs](https://github.com/sureserverman/nice-dns/issues?q=is%3Aissue+is%3Aopen+label%3Abug+sort%3Areactions-%2B1-desc) (Add your votes using the 👍 reaction)
- [Newest Bugs](https://github.com/sureserverman/nice-dns/issues?q=is%3Aopen+is%3Aissue+label%3Abug)

## Project assistance

If you want to say **thank you** or/and support active development of nice-dns:

- Add a [GitHub Star](https://github.com/sureserverman/nice-dns) to the project.
- Tweet about the nice-dns.
- Write interesting articles about the project on [Dev.to](https://dev.to/), [Medium](https://medium.com/) or your personal blog.

Together, we can make nice-dns **better**!

## Authors & contributors

The original setup of this repository is by [Serverman](https://github.com/sureserverman).

For a full list of all authors and contributors, see [the contributors page](https://github.com/sureserverman/nice-dns/contributors).

## Security

nice-dns follows good practices of security, but 100% security cannot be assured.
nice-dns is provided **"as is"** without any **warranty**. Use at your own risk.

## License

This project is licensed under the **GPLv3 license**.

See [LICENSE](LICENSE.md) for more information.
