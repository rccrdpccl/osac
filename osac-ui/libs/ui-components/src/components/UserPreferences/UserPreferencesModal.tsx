import * as React from 'react';
import {
  Button,
  FormGroup,
  MenuToggle,
  MenuToggleElement,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
  Select,
  SelectOption,
} from '@patternfly/react-core';

import { useSession } from '../../hooks/use-session';
import { Contrast, Theme } from '../../hooks/use-theme';
import { useTranslation } from '../../hooks/useTranslation';
import OsacForm from '../Form/OsacForm';

type UserPreferencesModalProps = {
  onClose: VoidFunction;
};

const UserPreferencesModal: React.FC<UserPreferencesModalProps> = ({ onClose }) => {
  const { t } = useTranslation();
  const { userTheme, setUserTheme, userContrast, setUserContrast } = useSession();
  const [themeExpanded, setThemeExpanded] = React.useState(false);
  const [contrastExpanded, setContrastExpanded] = React.useState(false);

  const themeOptions: { value: Theme; label: string }[] = [
    { value: 'system', label: t('System default') },
    { value: 'light', label: t('Light') },
    { value: 'dark', label: t('Dark') },
  ];

  const contrastOptions: { value: Contrast; label: string; description: string }[] = [
    {
      value: 'system',
      label: t('System default'),
      description: t("Matches your operating system's contrast setting."),
    },
    {
      value: 'glass',
      label: t('Glass'),
      description: t('A modern, visually refreshed console appearance.'),
    },
    {
      value: 'default',
      label: t('Traditional'),
      description: t('The traditional console appearance.'),
    },
    {
      value: 'contrast',
      label: t('High contrast'),
      description: t('Enhances contrast between interface elements for readability.'),
    },
  ];

  const selectedThemeLabel =
    themeOptions.find((option) => option.value === userTheme)?.label ?? t('System default');
  const selectedContrastLabel =
    contrastOptions.find((option) => option.value === userContrast)?.label ?? t('System default');

  return (
    <Modal isOpen variant="small" onClose={onClose}>
      <ModalHeader title={t('User preferences')} />
      <ModalBody>
        <OsacForm>
          <FormGroup label={t('Theme')}>
            <Select
              toggle={(toggleRef: React.Ref<MenuToggleElement>) => (
                <MenuToggle
                  ref={toggleRef}
                  className="pf-v6-u-w-100"
                  onClick={() => setThemeExpanded((prev) => !prev)}
                  isExpanded={themeExpanded}
                >
                  {selectedThemeLabel}
                </MenuToggle>
              )}
              selected={userTheme}
              onSelect={(_, value) => {
                setUserTheme(value as Theme);
                setThemeExpanded(false);
              }}
              aria-label={t('Theme')}
              isOpen={themeExpanded}
              onOpenChange={setThemeExpanded}
            >
              {themeOptions.map((option) => (
                <SelectOption key={option.value} value={option.value}>
                  {option.label}
                </SelectOption>
              ))}
            </Select>
          </FormGroup>
          <FormGroup label={t('Contrast mode')}>
            <Select
              toggle={(toggleRef: React.Ref<MenuToggleElement>) => (
                <MenuToggle
                  ref={toggleRef}
                  className="pf-v6-u-w-100"
                  onClick={() => setContrastExpanded((prev) => !prev)}
                  isExpanded={contrastExpanded}
                >
                  {selectedContrastLabel}
                </MenuToggle>
              )}
              selected={userContrast}
              onSelect={(_, value) => {
                setUserContrast(value as Contrast);
                setContrastExpanded(false);
              }}
              aria-label={t('Contrast mode')}
              isOpen={contrastExpanded}
              onOpenChange={setContrastExpanded}
            >
              {contrastOptions.map((option) => (
                <SelectOption
                  key={option.value}
                  value={option.value}
                  description={option.description}
                >
                  {option.label}
                </SelectOption>
              ))}
            </Select>
          </FormGroup>
        </OsacForm>
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" onClick={onClose}>
          {t('Close')}
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default UserPreferencesModal;
