# shellcheck shell=bash
# nd_root_deb / nd_root_mac <verb> [args]: the one way installer code runs a
# step as root (Sub-plan 5): the verb of deb/root-ops or mac/root-ops in the
# tree the install runs from (ND_INST_TREE), under sudo from a terminal.
# The verbs, their arguments and what each one does: those scripts.
nd_root_deb() { sudo bash "${ND_INST_TREE:?}"/deb/root-ops "$@"; }
nd_root_mac() { sudo bash "${ND_INST_TREE:?}"/mac/root-ops "$@"; }
