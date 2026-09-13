"""Reuse full predecessor/process audit, replacing only primitive oracle contract."""
from pathlib import Path
source=Path(__file__).with_name('apron_tight_audit.py').read_text()
old="primitive.get('checks')!=74016 or primitive.get('expected_checks')!=74016 or primitive.get('max_error_units',999)>76"
new="primitive.get('checks')!=148032 or primitive.get('expected_checks')!=148032 or primitive.get('weight_cells')!=74016 or primitive.get('min_slack_units',-1)<0 or primitive.get('max_allowance_units',9999)>1206"
assert source.count(old)==1
source=source.replace(old,new).replace('polynomial_checks=74016','local_endpoint_checks=148032')
exec(compile(source,str(Path(__file__)), 'exec'))
