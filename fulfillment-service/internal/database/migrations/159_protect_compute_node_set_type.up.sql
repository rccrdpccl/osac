-- A cluster reserves VM compute quota even before its first worker exists.
-- Keep the referenced sizing profile available until its cluster is archived.
create function check_compute_node_set_type_not_in_use() returns trigger as $$
begin
  if exists (
    select 1 from clusters c, jsonb_each(c.data->'spec'->'node_sets') n
    where n.value->'compute_instance_type'->>'id' = old.id
  ) then
    raise exception using errcode = 'Z0003',
      message = format('cannot delete instance type ''%s'': it is in use by a cluster', old.id);
  end if;
  return new;
end;
$$ language plpgsql;

create trigger check_compute_node_set_type_not_in_use
  before update of deletion_timestamp on instance_types
  for each row when (old.deletion_timestamp = 'epoch' and new.deletion_timestamp <> 'epoch')
  execute function check_compute_node_set_type_not_in_use();
