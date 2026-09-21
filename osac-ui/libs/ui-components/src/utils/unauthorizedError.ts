export class UnauthorizedError extends Error {
  constructor(message = 'You are not authorized to access this resource.') {
    super(message);
    this.name = 'UnauthorizedError';
  }
}

export const isUnauthorizedError = (error: unknown): error is UnauthorizedError =>
  error instanceof UnauthorizedError;
