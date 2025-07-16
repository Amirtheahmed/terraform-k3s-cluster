---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kured
  namespace: kube-system
spec:
  template:
    spec:
      containers:
        - name: kured
          command:
            - /usr/bin/kured
            %{~ for key, value in options ~}
            - --${key}=${value}
            %{~ endfor ~}