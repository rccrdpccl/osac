import { screen } from '@testing-library/react';
import { Formik } from 'formik';
import { describe, expect, it } from 'vitest';
import * as Yup from 'yup';

import { KeyValueMapField, type KeyValuePair } from './KeyValueMapField';
import { renderWithProviders } from '../../test-utils/TestProviders';

const renderField = (
  initialPairs: KeyValuePair[] = [],
  props: Partial<React.ComponentProps<typeof KeyValueMapField>> = {},
) =>
  renderWithProviders(
    <Formik
      initialValues={{ labels: initialPairs }}
      validationSchema={Yup.object({
        labels: Yup.array().min(1, 'At least one label is required'),
      })}
      onSubmit={() => undefined}
    >
      {({ submitForm }) => (
        <>
          <KeyValueMapField
            name="labels"
            fieldId="labels"
            label="Labels"
            isRequired
            addLabel="Add label"
            removeLabel="Remove label"
            {...props}
          />
          <button type="button" onClick={() => void submitForm()}>
            Submit
          </button>
        </>
      )}
    </Formik>,
  );

describe('KeyValueMapField', () => {
  it('renders the group label and an add action with no rows initially', () => {
    renderField();

    expect(screen.getByText('Labels')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add label' })).toBeInTheDocument();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });

  it('appends an empty key/value pair when the add action is clicked', async () => {
    const { user } = renderField();

    await user.click(screen.getByRole('button', { name: 'Add label' }));

    expect(screen.getByRole('textbox', { name: 'Labels key 1' })).toHaveValue('');
    expect(screen.getByRole('textbox', { name: 'Labels value 1' })).toHaveValue('');
  });

  it('pre-populates rows from the initial value and edits them independently', async () => {
    const { user } = renderField([
      { key: 'tier', value: 'gpu' },
      { key: 'zone', value: 'a' },
    ]);

    const keyInputs = screen.getAllByRole('textbox', { name: /Labels key/ });
    expect(keyInputs).toHaveLength(2);
    expect(keyInputs[0]).toHaveValue('tier');

    await user.clear(screen.getByRole('textbox', { name: 'Labels value 2' }));
    await user.type(screen.getByRole('textbox', { name: 'Labels value 2' }), 'b');

    expect(screen.getByRole('textbox', { name: 'Labels value 1' })).toHaveValue('gpu');
    expect(screen.getByRole('textbox', { name: 'Labels value 2' })).toHaveValue('b');
  });

  it('removes the targeted pair, leaving the others intact', async () => {
    const { user } = renderField([
      { key: 'tier', value: 'gpu' },
      { key: 'zone', value: 'a' },
    ]);

    await user.click(screen.getAllByRole('button', { name: 'Remove label' })[0]);

    const remaining = screen.getAllByRole('textbox', { name: /Labels key/ });
    expect(remaining).toHaveLength(1);
    expect(remaining[0]).toHaveValue('zone');
  });

  it('surfaces the array-level required error after a submit attempt', async () => {
    const { user } = renderField();

    expect(screen.queryByText('At least one label is required')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Submit' }));

    expect(await screen.findByText('At least one label is required')).toBeInTheDocument();
  });
});
