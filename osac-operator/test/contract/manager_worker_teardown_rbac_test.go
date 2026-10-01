/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package contract

import (
	"path/filepath"
	"slices"
	"testing"
)

func TestManagerWorkerTeardownReadPermissions(t *testing.T) {
	roles := map[string]clusterRole{
		"generated": loadClusterRoleFile(t, filepath.Join(repoRoot(), "osac-operator/config/rbac/role.yaml")),
		"Helm": loadHelmClusterRoleTemplate(t,
			filepath.Join(repoRoot(), "osac-operator/charts/operator/templates/clusterrole.yaml")),
	}
	for name, role := range roles {
		t.Run(name, func(t *testing.T) {
			for group, resources := range map[string][]string{
				"":                           {"namespaces"},
				"osac.openshift.io":          {"clusterorders"},
				"hypershift.openshift.io":    {"hostedclusters", "nodepools"},
				"agent-install.openshift.io": {"agents", "infraenvs"},
				"cluster.x-k8s.io":           {"machinedeployments", "machinesets", "machines"},
				"capi-provider.agent-install.openshift.io": {"agentmachines"},
			} {
				for _, resource := range resources {
					verbs := map[string]bool{}
					for _, rule := range role.Rules {
						if (slices.Contains(rule.APIGroups, group) || slices.Contains(rule.APIGroups, "*")) &&
							(slices.Contains(rule.Resources, resource) || slices.Contains(rule.Resources, "*")) {
							for _, verb := range rule.Verbs {
								verbs[verb] = true
							}
						}
					}
					for _, verb := range []string{"get", "list"} {
						if !verbs[verb] {
							t.Errorf("missing %s on %s.%s", verb, resource, group)
						}
					}
					if group == "cluster.x-k8s.io" || group == "capi-provider.agent-install.openshift.io" {
						for verb := range verbs {
							if verb != "get" && verb != "list" {
								t.Errorf("unexpected %s on %s.%s: recovery is read-only", verb, resource, group)
							}
						}
					}
				}
			}
		})
	}
}
