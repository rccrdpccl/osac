import React from 'react';

interface CidrDisplayProps {
  ipv4Cidr?: string;
  ipv6Cidr?: string;
}

export const CidrDisplay: React.FC<CidrDisplayProps> = ({ ipv4Cidr, ipv6Cidr }) => {
  // If both exist, show on separate lines with labels
  if (ipv4Cidr && ipv6Cidr) {
    return (
      <div>
        <div>IPv4: {ipv4Cidr}</div>
        <div>IPv6: {ipv6Cidr}</div>
      </div>
    );
  }

  // Otherwise just show whichever one exists (or dash)
  return <>{ipv4Cidr || ipv6Cidr || '—'}</>;
};
