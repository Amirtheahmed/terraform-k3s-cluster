# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-07-22

### Added
- Initial release of terraform-k3s-bare-metal module
- Support for openSUSE MicroOS
- Automated k3s installation and configuration
- Essential addons: Kured, System Upgrade Controller, Cert-Manager
- Optional addons: External-DNS, Longhorn
- CNI support for Flannel and Cilium
- Custom manifest deployment via Kustomize
- Comprehensive examples and documentation