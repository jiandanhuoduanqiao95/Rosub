#用于申请证书，实现消息加密
from OpenSSL import crypto

def generate_self_signed_cert(cert_file, key_file, pem_file, domain_list, email):
    # 创建一个新的私钥
    key = crypto.PKey()
    key.generate_key(crypto.TYPE_RSA, 2048)


    # 创建一个新的证书请求
    req = crypto.X509Req()
    subj = req.get_subject()
    subj.CN = domain_list[0]  # 将第一个域名作为 CN
    subj.emailAddress = email
    req.set_pubkey(key)

    # 使用扩展来设置 Subject Alternative Names (SAN)
    san_list = [f"DNS:{domain}" for domain in domain_list]
    san_extension = crypto.X509Extension(
        b"subjectAltName", False, ", ".join(san_list).encode()
    )

    req.add_extensions([san_extension])
    req.sign(key, "sha256")

    # 创建一个自签名证书
    cert = crypto.X509()
    cert.set_serial_number(1000)
    cert.gmtime_adj_notBefore(0)
    cert.gmtime_adj_notAfter(365 * 24 * 60 * 60)  # 有效期为一年
    cert.set_issuer(req.get_subject())
    cert.set_subject(req.get_subject())
    cert.set_pubkey(req.get_pubkey())

    # 添加 SAN 扩展到证书
    cert.add_extensions([san_extension])

    cert.sign(key, "sha256")

    # 将证书和私钥保存到文件中
    with open(cert_file, "wb") as certfile:
        certfile.write(crypto.dump_certificate(crypto.FILETYPE_PEM, cert))
    with open(key_file, "wb") as keyfile:
        keyfile.write(crypto.dump_privatekey(crypto.FILETYPE_PEM, key))
    with open(pem_file, "wb") as pemfile:
        pemfile.write(crypto.dump_privatekey(crypto.FILETYPE_PEM, key))
        pemfile.write(crypto.dump_certificate(crypto.FILETYPE_PEM, cert))

    print(f"生成的 SSL 证书存储在 {cert_file}")
    print(f"生成的 SSL 私钥存储在 {key_file}")
    print(f"生成的 PEM 文件存储在 {pem_file}")

if __name__ == "__main__":
    domain_list = ["tset.cn"]  # 替换为多个域名
    email = "133885726+jiandanhuoduanqiao95@users.noreply.github.com"  # 替换为实际的电子邮件地址
    cert_file = domain_list[0].replace(".", "") + ".crt"
    key_file = domain_list[0].replace(".", "") + ".key"
    pem_file = domain_list[0].replace(".", "") + ".pem"
    generate_self_signed_cert(cert_file, key_file, pem_file, domain_list, email)