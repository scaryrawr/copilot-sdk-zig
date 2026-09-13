pub const data = @embedFile("protocol-parity-requirements.tsv");
pub const expected_required_row_count: usize = 55;
pub const expected_unique_evidence_command_count: usize = 19;
pub const expected_case_id_sha256 = "9aea595abb39b20dc3f484101f7313c4ab4e62a11b369093134b39a487969436";
pub const expected_mapping_sha256 = "890943290da3792c36ceb7a057749fe1ffcf466165581fe4802a3ae93470dad7";
pub const expected_taxonomy_emitted: usize = 71;
pub const expected_taxonomy_declared_not_emitted: usize = 7;
pub const expected_taxonomy_triples: usize = 145;
