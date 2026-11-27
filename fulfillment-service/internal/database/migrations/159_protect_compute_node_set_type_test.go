// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

package migrations

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
	. "github.com/onsi/ginkgo/v2/dsl/core"
	. "github.com/onsi/gomega"
)

var _ = DescribeMigration("Protect compute node set type", func() {
	It("keeps an unprovisioned worker's type until its cluster is archived", func(ctx context.Context) {
		Expect(tool.Migrate(ctx, 159)).To(Succeed())
		_, err := conn.Exec(ctx, `insert into instance_types (id,name,tenant,data) values ('small','small','shared','{}');
  insert into clusters (id,name,tenant,data) values ('c','c','system','{"spec":{"node_sets":{"workers":{"compute_instance_type":{"id":"small"}}}}}')`)
		Expect(err).NotTo(HaveOccurred())
		const softDelete = `update instance_types set deletion_timestamp=now() where id='small'`
		_, err = conn.Exec(ctx, softDelete)
		var blocked *pgconn.PgError
		Expect(errors.As(err, &blocked)).To(BeTrue())
		Expect(blocked.Code).To(Equal("Z0003"))
		_, err = conn.Exec(ctx, "delete from clusters where id='c'")
		Expect(err).NotTo(HaveOccurred())
		_, err = conn.Exec(ctx, softDelete)
		Expect(err).NotTo(HaveOccurred())
	})
})
