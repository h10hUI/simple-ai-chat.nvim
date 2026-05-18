// LSP diagnostics 確認用のサンプル TS ファイル。
// 意図的に複数種類のエラー・警告を含めている。

interface User {
  id: number;
  name: string;
}

function greet(user: User): string {
  return "Hello, " + user.name;
}

// [error] 引数の型が違う（number は User に代入不可）
const a = greet(42);

// [error] 未定義の参照
console.log(unknownVariable);

// [warn] 未使用ローカル
const unused = 100;

// [error] 戻り値型の不一致（string を返すべきところで number）
function getId(user: User): string {
  return user.id;
}

// [error] 関数の戻り値が分岐で欠落（noImplicitReturns）
function maybe(flag: boolean): number {
  if (flag) {
    return 1;
  }
}

// [warn] 未使用引数
function noop(input: string) {
  return "ok";
}

export { greet, getId, maybe, noop, a };
