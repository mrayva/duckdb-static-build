#!/usr/bin/env python3
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

def rewrite(rel, pattern, replacement, expected=1):
    path = root / rel
    text = path.read_text()
    new_text, count = re.subn(pattern, replacement, text, flags=re.S)
    if count != expected:
        raise SystemExit(f"cast API rewrite in {rel}: expected {expected}, found {count}")
    path.write_text(new_text)

rewrite("src/core/ivm_view_classifier.cpp", r"static BoundColumnRefExpression \*GetColumnRefThroughCasts\(Expression \*expr\) \{.*?\n\}", """static BoundColumnRefExpression *GetColumnRefThroughCasts(Expression *expr) {
\twhile (expr && BoundCastExpression::IsCast(*expr)) {
\t\tauto &cast = expr->Cast<BoundFunctionExpression>();
\t\texpr = const_cast<Expression *>(&BoundCastExpression::Child(cast));
\t}
\tif (!expr || expr->GetExpressionType() != ExpressionType::BOUND_COLUMN_REF) {
\t\treturn nullptr;
\t}
\treturn &expr->Cast<BoundColumnRefExpression>();
}""")
rewrite("src/core/parser_plan_helpers.cpp", r"\tif \(expr->GetExpressionType\(\) == ExpressionType::BOUND_COLUMN_REF\) \{\n\t\treturn true;\n\t\}\n\tif \(expr->GetExpressionClass\(\) == ExpressionClass::BOUND_CAST\) \{.*?\n\t\}\n\treturn false;", """\tif (expr->GetExpressionType() == ExpressionType::BOUND_COLUMN_REF) {
\t\treturn true;
\t}
\tif (BoundCastExpression::IsCast(*expr)) {
\t\tauto &cast = expr->Cast<BoundFunctionExpression>();
\t\treturn IsPurePassThroughExpression(&BoundCastExpression::Child(cast));
\t}
\treturn false;""")
rewrite("src/core/parser_plan_helpers.cpp", r"static BoundColumnRefExpression \*GetColumnRefThroughCasts\(Expression \*expr\) \{.*?\n\}", """static BoundColumnRefExpression *GetColumnRefThroughCasts(Expression *expr) {
\twhile (expr && BoundCastExpression::IsCast(*expr)) {
\t\tauto &cast = expr->Cast<BoundFunctionExpression>();
\t\texpr = const_cast<Expression *>(&BoundCastExpression::Child(cast));
\t}
\tif (!expr || expr->GetExpressionType() != ExpressionType::BOUND_COLUMN_REF) {
\t\treturn nullptr;
\t}
\treturn &expr->Cast<BoundColumnRefExpression>();
}""")
rewrite("src/include/delta/operators/join_key_probe.hpp", r"\tif \(expr\.GetExpressionClass\(\) == ExpressionClass::BOUND_CAST\) \{.*?\n\t\}\n", """\tif (BoundCastExpression::IsCast(expr)) {
\t\tauto &cast = expr.Cast<BoundFunctionExpression>();
\t\treturn TryGetDeltaJoinColumnRef(const_cast<Expression &>(BoundCastExpression::Child(cast)), binding);
\t}
""")
rewrite("src/core/plan_rewrite.cpp", r"static string HavingExprToSQL\(const Expression &expr, const unordered_map<uint64_t, string> &binding_to_alias\) \{", """static string HavingExprToSQL(const Expression &expr, const unordered_map<uint64_t, string> &binding_to_alias) {
\tif (BoundCastExpression::IsCast(expr)) {
\t\tconst auto &cast = expr.Cast<BoundFunctionExpression>();
\t\treturn HavingExprToSQL(BoundCastExpression::Child(cast), binding_to_alias);
\t}""")
rewrite("src/core/plan_rewrite.cpp", r"\n\tcase ExpressionClass::BOUND_CAST: \{\n\t\treturn HavingExprToSQL\(expr\.Cast<BoundCastExpression>\(\)\.Child\(\), binding_to_alias\);\n\t\}", "")

lpts = root / "third_party/lpts/src/lpts_expression_renderer.cpp"
text = lpts.read_text()
text, count = re.subn(r"\n\tcase ExpressionClass::BOUND_CAST: \{.*?\n\t\}\n\tcase ExpressionClass::BOUND_CONJUNCTION:", "\n\tcase ExpressionClass::BOUND_CONJUNCTION:", text, flags=re.S)
if count != 1:
    raise SystemExit(f"cast API rewrite in {lpts}: expected cast case, found {count}")
marker = "\tconst ExpressionClass e_class = expression.GetExpressionClass();"
prefix = """\tif (BoundCastExpression::IsCast(expression)) {
\t\tconst auto &cast_expr = expression.Cast<BoundFunctionExpression>();
\t\tstd::ostringstream cast_str;
\t\tif (BoundCastExpression::IsTryCast(cast_expr)) {
\t\t\tValidateTryCastForDialect(dialect);
\t\t}
\t\tif (TypeContainsUnnamedStruct(cast_expr.GetReturnType()) &&
\t\t    TypesEqualIgnoringStructNames(BoundCastExpression::Child(cast_expr).GetReturnType(), cast_expr.GetReturnType())) {
\t\t\treturn ExpressionToAliasedString(BoundCastExpression::Child(cast_expr));
\t\t}
\t\tif (TypeContainsNullType(cast_expr.GetReturnType())) {
\t\t\treturn ExpressionToAliasedString(BoundCastExpression::Child(cast_expr));
\t\t}
\t\tcast_str << (BoundCastExpression::IsTryCast(cast_expr) ? "TRY_CAST(" : "CAST(");
\t\tcast_str << ExpressionToAliasedString(BoundCastExpression::Child(cast_expr));
\t\tcast_str << " AS " << RenderCastTargetType(cast_expr.GetReturnType(), dialect) << ")";
\t\treturn cast_str.str();
\t}
\tconst ExpressionClass e_class = expression.GetExpressionClass();"""
if text.count(marker) != 1:
    raise SystemExit("cast API rewrite: LPTS renderer marker not unique")
lpts.write_text(text.replace(marker, prefix))
