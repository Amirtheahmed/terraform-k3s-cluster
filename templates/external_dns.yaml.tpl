---
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: external-dns
  namespace: kube-system
spec:
  chart: external-dns
  repo: https://kubernetes-sigs.github.io/external-dns/
  targetNamespace: external-dns
  valuesContent: |-
    ${values}