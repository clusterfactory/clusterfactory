#!/usr/bin/env python3
"""Validate oscal-component.yaml against the NIST OSCAL component-definition JSON schema.

The NIST schema uses Unicode property escapes (\\p{L}, \\p{N}) that Python's
`re` does not support; they are rewritten to equivalent classes before
validation. Usage: hack/oscal-validate.py <schema.json> [oscal-component.yaml]
"""
import json
import sys

import jsonschema
import yaml

schema_path = sys.argv[1]
doc_path = sys.argv[2] if len(sys.argv) > 2 else "oscal-component.yaml"

raw = open(schema_path).read()
raw = raw.replace("\\\\p{L}", "[^\\\\W\\\\d_]").replace("\\\\p{N}", "\\\\d")
schema = json.loads(raw)
doc = yaml.safe_load(open(doc_path))

jsonschema.Draft7Validator.check_schema(schema)
errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.absolute_path))
if errors:
    for e in errors[:10]:
        print(f"INVALID at /{'/'.join(map(str, e.absolute_path))}: {e.message[:200]}")
    sys.exit(1)
print(f"{doc_path} is valid against {schema_path}")
