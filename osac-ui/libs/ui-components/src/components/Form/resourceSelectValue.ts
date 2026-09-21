export interface ResourceSelectValue {
  id: string;
  name: string;
}

export const emptyResourceSelectValue = (): ResourceSelectValue => ({ id: '', name: '' });
