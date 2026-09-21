import { fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Form, Formik } from 'formik';
import { describe, expect, it, vi } from 'vitest';

import NumberField from './NumberField';

describe('NumberField', () => {
  it('preserves bigint precision when submitting a large integer', async () => {
    const onSubmit = vi.fn();
    const user = userEvent.setup();

    render(
      <Formik initialValues={{ capacityGb: undefined as bigint | undefined }} onSubmit={onSubmit}>
        <Form>
          <NumberField
            name="capacityGb"
            label="Capacity (GiB)"
            fieldId="capacity-gib"
            type="bigint"
          />
          <button type="submit">Submit</button>
        </Form>
      </Formik>,
    );

    await user.type(screen.getByRole('textbox', { name: 'Capacity (GiB)' }), '9007199254740993');
    await user.click(screen.getByRole('button', { name: 'Submit' }));

    expect(onSubmit).toHaveBeenCalledWith({ capacityGb: 9007199254740993n }, expect.any(Object));
  });

  it('stores an empty numeric field as undefined', async () => {
    const onSubmit = vi.fn();
    const user = userEvent.setup();

    render(
      <Formik initialValues={{ cores: 2 }} onSubmit={onSubmit}>
        <Form>
          <NumberField name="cores" label="Cores" fieldId="cores" />
          <button type="submit">Submit</button>
        </Form>
      </Formik>,
    );

    await user.clear(screen.getByRole('spinbutton', { name: 'Cores' }));
    await user.click(screen.getByRole('button', { name: 'Submit' }));

    expect(onSubmit).toHaveBeenCalledWith({ cores: undefined }, expect.any(Object));
  });

  it('rejects decimal values', () => {
    render(
      <Formik initialValues={{ cores: undefined as number | undefined }} onSubmit={() => undefined}>
        <NumberField name="cores" label="Cores" fieldId="cores" />
      </Formik>,
    );

    const input = screen.getByRole('spinbutton', { name: 'Cores' });
    fireEvent.change(input, { target: { value: '2.5' } });

    expect(input).toHaveValue(null);
  });
});
