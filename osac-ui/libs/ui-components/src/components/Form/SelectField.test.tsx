import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Formik, type FormikErrors } from 'formik';
import { describe, expect, it } from 'vitest';
import * as yup from 'yup';

import { SelectField } from './SelectField';

const renderSelect = ({
  autoSelectSingleOption = false,
  initialValue = '',
  isLoading = false,
}: {
  autoSelectSingleOption?: boolean;
  initialValue?: string;
  isLoading?: boolean;
} = {}) => {
  let latestErrors: FormikErrors<{ kind: string }> = {};

  render(
    <Formik
      initialValues={{ kind: initialValue }}
      validationSchema={yup.object({
        kind: yup.string().required('Kind is required'),
      })}
      onSubmit={() => undefined}
    >
      {({ validateForm, values }) => (
        <>
          <SelectField
            name="kind"
            label="Kind"
            fieldId="kind"
            isRequired
            autoSelectSingleOption={autoSelectSingleOption}
            isLoading={isLoading}
            placeholder="Select a kind"
            options={[{ value: 'only-option', label: 'Only option label' }]}
          />
          <output aria-label="formik-value">{values.kind || '(empty)'}</output>
          <button
            type="button"
            onClick={() => {
              void validateForm().then((errors) => {
                latestErrors = errors;
              });
            }}
          >
            Validate
          </button>
        </>
      )}
    </Formik>,
  );

  return {
    getLatestErrors: () => latestErrors,
  };
};

describe('SelectField', () => {
  it('shows the placeholder on the toggle when no value is selected', () => {
    renderSelect();

    expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Select a kind');
  });

  it('auto-selects a single option into Formik when not loading', async () => {
    renderSelect({ autoSelectSingleOption: true });

    await waitFor(() => {
      expect(screen.getByLabelText('formik-value')).toHaveTextContent('only-option');
    });

    expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Only option label');
  });

  it('does not auto-select while loading', async () => {
    renderSelect({ autoSelectSingleOption: true, isLoading: true });

    await waitFor(() => {
      expect(screen.getByLabelText('formik-value')).toHaveTextContent('(empty)');
    });

    expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Loading...');
  });

  it('passes validation after auto-selecting the only option', async () => {
    const user = userEvent.setup();
    const view = renderSelect({ autoSelectSingleOption: true });

    await waitFor(() => {
      expect(screen.getByLabelText('formik-value')).toHaveTextContent('only-option');
    });

    await user.click(screen.getByRole('button', { name: 'Validate' }));

    expect(view.getLatestErrors()).toEqual({});
  });

  it('does not auto-select when multiple options are available', async () => {
    render(
      <Formik initialValues={{ kind: '' }} onSubmit={() => undefined}>
        {({ values }) => (
          <>
            <SelectField
              name="kind"
              label="Kind"
              fieldId="kind"
              autoSelectSingleOption
              placeholder="Select a kind"
              options={[
                { value: 'small', label: 'Small' },
                { value: 'large', label: 'Large' },
              ]}
            />
            <output aria-label="formik-value">{values.kind || '(empty)'}</output>
          </>
        )}
      </Formik>,
    );

    await waitFor(() => {
      expect(screen.getByLabelText('formik-value')).toHaveTextContent('(empty)');
    });

    expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Select a kind');
  });

  it('updates Formik when the user selects an option', async () => {
    const user = userEvent.setup();

    render(
      <Formik initialValues={{ kind: '' }} onSubmit={() => undefined}>
        {({ values }) => (
          <>
            <SelectField
              name="kind"
              label="Kind"
              fieldId="kind"
              placeholder="Select a kind"
              options={[
                { value: 'small', label: 'Small' },
                { value: 'large', label: 'Large' },
              ]}
            />
            <output aria-label="formik-value">{values.kind || '(empty)'}</output>
          </>
        )}
      </Formik>,
    );

    await user.click(screen.getByLabelText(/^Kind/));
    await user.click(screen.getByRole('option', { name: 'Large' }));

    await waitFor(() => {
      expect(screen.getByLabelText('formik-value')).toHaveTextContent('large');
    });
    expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Large');
  });

  it('does not show a required error immediately after selecting an option with validateOnBlur', async () => {
    const user = userEvent.setup();

    render(
      <Formik
        initialValues={{ kind: '' }}
        validateOnBlur
        validationSchema={yup.object({
          kind: yup.string().required('Kind is required'),
        })}
        onSubmit={() => undefined}
      >
        {() => (
          <SelectField
            name="kind"
            label="Kind"
            fieldId="kind"
            isRequired
            placeholder="Select a kind"
            options={[
              { value: 'small', label: 'Small' },
              { value: 'large', label: 'Large' },
            ]}
          />
        )}
      </Formik>,
    );

    await user.click(screen.getByLabelText(/^Kind/));
    await user.click(screen.getByRole('option', { name: 'Large' }));

    await waitFor(() => {
      expect(screen.getByLabelText(/^Kind/)).toHaveTextContent('Large');
    });
    expect(screen.queryByText('Kind is required')).not.toBeInTheDocument();
  });
});
