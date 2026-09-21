import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';

import CreateButton from './CreateButton';

describe('CreateButton', () => {
  describe('rendering', () => {
    it('renders as a primary button with a plus icon', () => {
      render(<CreateButton>Create item</CreateButton>);

      const button = screen.getByRole('button', { name: 'Create item' });
      expect(button).toHaveClass('pf-m-primary');
      expect(button.querySelector('.pf-v6-c-button__icon')).not.toBeNull();
    });

    it('applies a custom variant', () => {
      render(<CreateButton variant="secondary">Create item</CreateButton>);

      expect(screen.getByRole('button', { name: 'Create item' })).toHaveClass('pf-m-secondary');
    });
  });

  describe('user interactions', () => {
    it('calls onClick when used as a button', async () => {
      const user = userEvent.setup();
      const onClick = vi.fn();

      render(<CreateButton onClick={onClick}>Create item</CreateButton>);

      await user.click(screen.getByRole('button', { name: 'Create item' }));

      expect(onClick).toHaveBeenCalledTimes(1);
    });
  });

  describe('when to is provided', () => {
    it('renders as a link to the given route', () => {
      render(
        <MemoryRouter>
          <CreateButton to="/items/create">Create item</CreateButton>
        </MemoryRouter>,
      );

      const link = screen.getByRole('link', { name: 'Create item' });
      expect(link).toHaveAttribute('href', '/items/create');
      expect(link).toHaveClass('pf-m-primary');
      expect(link.querySelector('.pf-v6-c-button__icon')).not.toBeNull();
      expect(screen.queryByRole('button', { name: 'Create item' })).not.toBeInTheDocument();
    });

    it('navigates to the given route when clicked', async () => {
      const user = userEvent.setup();

      render(
        <MemoryRouter initialEntries={['/items']}>
          <Routes>
            <Route
              path="/items"
              element={<CreateButton to="/items/create">Create item</CreateButton>}
            />
            <Route path="/items/create" element={<h1>Create page</h1>} />
          </Routes>
        </MemoryRouter>,
      );

      await user.click(screen.getByRole('link', { name: 'Create item' }));

      expect(screen.getByRole('heading', { name: 'Create page' })).toBeInTheDocument();
    });
  });
});
