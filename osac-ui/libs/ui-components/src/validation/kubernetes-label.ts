const DNS_LABEL_PATTERN = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;
const LABEL_NAME_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$/;

export const isKubernetesLabelKey = (value: string): boolean => {
  const parts = value.split('/');
  const [prefix, name] = parts.length === 2 ? parts : [undefined, parts[0]];

  if (parts.length > 2 || !name || name.length > 63 || !LABEL_NAME_PATTERN.test(name)) {
    return false;
  }

  return prefix === undefined || isKubernetesDnsSubdomain(prefix);
};

export const isKubernetesLabelValue = (value: string): boolean =>
  value === '' || (value.length <= 63 && LABEL_NAME_PATTERN.test(value));

const isKubernetesDnsSubdomain = (value: string): boolean =>
  value.length > 0 &&
  value.length <= 253 &&
  value.split('.').every((part) => part.length <= 63 && DNS_LABEL_PATTERN.test(part));
