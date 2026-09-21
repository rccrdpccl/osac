export interface TimestampProps {
  value?: ProtoTimestamp | string | Date | null;
  fallback?: string;
}

type ProtoTimestamp = {
  seconds?: bigint;
  nanos?: number;
};

const DISPLAY_FORMAT = new Intl.DateTimeFormat('en-US', {
  month: 'numeric',
  day: 'numeric',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

const isProtoTimestamp = (value: unknown): value is ProtoTimestamp => {
  if (!value || typeof value !== 'object') {
    return false;
  }
  return 'seconds' in value && 'nanos' in value;
};

const toDate = (value: ProtoTimestamp | string | Date): Date | undefined => {
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? undefined : value;
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) {
      return undefined;
    }
    const parsed = Date.parse(trimmed);
    return Number.isNaN(parsed) ? undefined : new Date(parsed);
  }
  if (isProtoTimestamp(value)) {
    if (value.seconds === undefined) {
      return undefined;
    }
    const ms = Number(value.seconds) * 1000 + Math.floor((value.nanos ?? 0) / 1_000_000);
    const date = new Date(ms);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  return undefined;
};

export const Timestamp = ({ value, fallback = '—' }: TimestampProps) => {
  if (!value) {
    return <>{fallback}</>;
  }

  const date = toDate(value);
  if (!date) {
    return <>{fallback}</>;
  }

  return <time dateTime={date.toISOString()}>{DISPLAY_FORMAT.format(date)}</time>;
};
