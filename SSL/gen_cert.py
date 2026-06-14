"""自签名 SSL 证书生成器（使用 cryptography 库）"""
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import datetime
import os

def generate_cert(cert_file, key_file, pem_file, domains):
    # 生成 RSA 私钥
    key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )

    # 构建证书主题
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "CN"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Beijing"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Beijing"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Chatroom"),
        x509.NameAttribute(NameOID.COMMON_NAME, domains[0]),
    ])

    # 构建 SAN 扩展
    san = x509.SubjectAlternativeName([x509.DNSName(d) for d in domains])

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=365 * 10))  # 10 年有效
        .add_extension(san, critical=False)
        .sign(key, hashes.SHA256(), default_backend())
    )

    # 保存
    with open(cert_file, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_file, "wb") as f:
        f.write(key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ))
    with open(pem_file, "wb") as f:
        f.write(key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ))
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    print(f"证书: {cert_file}")
    print(f"私钥: {key_file}")
    print(f"PEM:  {pem_file}")

if __name__ == "__main__":
    domains = ["tset.cn"]
    base = "tsetcn"
    # 备份旧证书
    for ext in [".crt", ".key", ".pem"]:
        old = f"SSL/{base}{ext}"
        if os.path.exists(old):
            os.rename(old, f"SSL/{base}{ext}.bak")
    generate_cert(f"SSL/{base}.crt", f"SSL/{base}.key", f"SSL/{base}.pem", domains)
