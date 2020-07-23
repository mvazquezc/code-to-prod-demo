#!/bin/bash
rm -rf /var/tmp/code-to-prod-demo/
CLUSTER_NAME="codetoprod"
kcli delete kube $CLUSTER_NAME
