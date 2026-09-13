pub const data = @embedFile("protocol-parity-requirements.tsv");
pub const expected_required_row_count: usize = 56;
pub const expected_unique_evidence_command_count: usize = 20;
pub const expected_case_id_sha256 = "34c86b9aaf4188369160d5d9f1e9dc2a280affd673af3633f13b26d893a1c9d3";
pub const expected_mapping_sha256 = "ba1c666964c718e1a7164cde81378f7614e10f70e02e3cb348cee5132ab6a093";
pub const expected_taxonomy_emitted: usize = 72;
pub const expected_taxonomy_declared_not_emitted: usize = 7;
pub const expected_taxonomy_triples: usize = 148;
