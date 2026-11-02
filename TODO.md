# Pendências

O que falta para cobrir tudo o que o SQL Server oferece. O histórico do port
está no git.

- Autenticação Windows (NTLM/Kerberos/SSPI) e Microsoft Entra ID (Azure AD).
- Table-valued parameters.
- Bulk copy (BULK INSERT pelo protocolo).
- MARS (`smp.py` do pytds).
- TDS 8.0 (strict encryption, TLS antes do PRELOGIN).
- Validação de certificado no backend OpenSSL (hoje só no tlslite).
- Teste do redirecionamento do Azure com TLS (hoje o gateway falso dos testes
  é sem TLS, então a validação contra o host de destino não está coberta).
