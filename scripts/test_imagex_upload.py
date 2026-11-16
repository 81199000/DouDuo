#!/usr/bin/env python3
"""评论发图的 ImageX 上传逻辑：签名、CRC32、三个请求怎么拼、回包怎么读。

Run: python3 scripts/test_imagex_upload.py -v
不联网，也不启动模拟器。签名另用 Python 标准库独立算一遍，和 Swift 的结果对账。
"""
import hashlib
import hmac
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DYImageXUploader.swift"

ACCESS_KEY = "AKTESTKEY"
SECRET = "c2VjcmV0LWZvci10ZXN0cw=="
TOKEN = "STS2token/with+odd=chars"
AMZ_DATE = "20261116T175300Z"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sign(method: str, query: dict, headers: dict, region="cn-north-1", service="imagex",
         access_key=ACCESS_KEY, secret=SECRET, amz_date=AMZ_DATE) -> str:
    """照 AWS Signature V4 文档写的参考实现，故意不看 Swift 那边怎么写。"""
    day = amz_date[:8]
    canonical_query = "&".join(
        f"{quote(k, safe='-_.~')}={quote(v, safe='-_.~')}" for k, v in sorted(query.items())
    )
    lowered = sorted((k.lower(), " ".join(v.split())) for k, v in headers.items())
    canonical_headers = "".join(f"{k}:{v}\n" for k, v in lowered)
    signed = ";".join(k for k, _ in lowered)
    body_hash = headers.get("X-Amz-Content-Sha256", sha256(b""))
    canonical = "\n".join([method, "/", canonical_query, canonical_headers, signed, body_hash])
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, sha256(canonical.encode())])
    key = ("AWS4" + secret).encode()
    for part in (day, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    return f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed}, Signature={signature}"


class ImageXUploadTests(unittest.TestCase):
    output = ""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix="douduo-imagex-") as tmp:
            binary = Path(tmp) / "imagex-logic"
            completed = subprocess.run(
                ["swiftc", "-parse-as-library", "-D", "DY_IMAGEX_MAIN", str(SOURCE), "-o", str(binary)],
                check=False, capture_output=True, text=True,
            )
            if completed.returncode != 0:
                raise AssertionError(completed.stdout + completed.stderr)
            ran = subprocess.run([str(binary)], check=False, capture_output=True, text=True)
        cls.output = ran.stdout
        if ran.returncode != 0:
            raise AssertionError(ran.stdout + ran.stderr)

    def line(self, prefix: str) -> str:
        for row in self.output.splitlines():
            if row.startswith(prefix + " "):
                return row[len(prefix) + 1:]
        self.fail(f"Swift 没输出 {prefix}")

    def test_logic_suite(self):
        self.assertIn("DYImageXLogicTests passed", self.output)

    def test_reference_matches_aws_vector(self):
        # 先确认这份参考实现本身是对的（AWS 官方测试集 get-vanilla）
        got = sign("GET", {}, {"Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"},
                   region="us-east-1", service="service", access_key="AKIDEXAMPLE",
                   secret="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", amz_date="20150830T123600Z")
        self.assertTrue(got.endswith("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"), got)

    def test_apply_signature_matches_reference(self):
        query = {"Action": "ApplyImageUpload", "Version": "2018-08-01", "ServiceId": "svc123",
                 "NeedFallback": "true", "FileSize": "34567", "s": "abc123"}
        headers = {"X-Amz-Date": AMZ_DATE, "x-amz-security-token": TOKEN}
        self.assertEqual(self.line("APPLY_AUTH"), sign("GET", query, headers))

    def test_commit_signature_matches_reference(self):
        body = b'{"SessionKey":"SESSION=="}'
        query = {"Action": "CommitImageUpload", "Version": "2018-08-01", "ServiceId": "svc123"}
        headers = {"X-Amz-Date": AMZ_DATE, "x-amz-security-token": TOKEN, "X-Amz-Content-Sha256": sha256(body)}
        self.assertEqual(self.line("COMMIT_AUTH"), sign("POST", query, headers))

    def test_credentials_never_logged(self):
        source = SOURCE.read_text()
        self.assertNotIn("DYLiveModel.log", source)
        self.assertNotIn("print(", source.split("#if DY_IMAGEX_MAIN")[0])
        self.assertNotIn("UserDefaults", source)


if __name__ == "__main__":
    unittest.main()
