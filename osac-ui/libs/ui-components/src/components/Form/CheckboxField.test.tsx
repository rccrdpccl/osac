import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Formik } from 'formik';
import { describe, expect, it } from 'vitest';

import { CheckboxField } from './CheckboxField';

const renderCheckbox = ({
  initialValue = false,
  isDisabled = false,
}: { initialValue?: boolean; isDisabled?: boolean } = {}) =>
  render(
    <Formik initialValues={{ encryptionEnabled: initialValue }} onSubmit={() => undefined}>
      {({ values }) => (
        <>
          <CheckboxField
            name="encryptionEnabled"
            label="Encryption enabled"
            fieldId="encryption-enabled"
            isDisabled={isDisabled}
          />
          <output aria-label="formik-value">{String(values.encryptionEnabled)}</output>
        </>
      )}
    </Formik>,
  );

describe('CheckboxField', () => {
  it('renders unchecked when the initial Formik value is false', () => {
    renderCheckbox();

    expect(screen.getByRole('checkbox', { name: 'Encryption enabled' })).not.toBeChecked();
  });

  it('renders checked when the initial Formik value is true', () => {
    renderCheckbox({ initialValue: true });

    expect(screen.getByRole('checkbox', { name: 'Encryption enabled' })).toBeChecked();
  });

  it('updates the Formik value when checked', async () => {
    const user = userEvent.setup();
    renderCheckbox();

    await user.click(screen.getByRole('checkbox', { name: 'Encryption enabled' }));

    expect(screen.getByLabelText('formik-value')).toHaveTextContent('true');
  });

  it('updates the Formik value when unchecked', async () => {
    const user = userEvent.setup();
    renderCheckbox({ initialValue: true });

    await user.click(screen.getByRole('checkbox', { name: 'Encryption enabled' }));

    expect(screen.getByLabelText('formik-value')).toHaveTextContent('false');
  });

  it('disables the checkbox when isDisabled is true', () => {
    renderCheckbox({ isDisabled: true });

    expect(screen.getByRole('checkbox', { name: 'Encryption enabled' })).toBeDisabled();
  });
});
