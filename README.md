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


> To create the application there are just a few commands to do in your teminal:\
> `git clone https://github.com/sureserverman/nice-dns.git`\
> `cd nice-dns`\
> Of course you'll need git and docker to be installed on your machine
> If you want to install it with persistent data dirs, so that you could change your settings and they'll survive reboot then run:\
> `sudo docker compose -f persistent-settings-compose.yml up -d`
> 
> If you want to install it with web interface for pi-hole enabled, then run following command:\
> `sudo docker compose -f webinterface-compose.yml up -d`
> 
> But my favorite way is to install it without web interface and without persistent volumes. This is the most secure way. 
> For two reasons: No possibility for any sort of logs to survive reboots and no possible vulnerabilities in web interface. For this option you just run:\
> `sudo docker compose up -d`
> 
> To install it on Ubuntu with one-line command try to use:\
> `bash <(curl -Ls https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh)`
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
