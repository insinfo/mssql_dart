#pragma once


#include <windows.h>
#include <oaidl.h>
#include <oleauto.h>
#include <comdef.h>
#include <comutil.h>
#include <atlbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "dart_api.h"
#include "dart_native_api.h"
#include "oledberr.h"
#include "msoledbsql.h"

#ifdef __cplusplus
extern "C" {
#endif


#ifndef CLSID_MSOLEDBSQL
    extern "C" const GUID CLSID_MSOLEDBSQL =
    { 0x0f1e4540, 0x64ba, 0x11d2, { 0x90, 0x86, 0x00, 0xc0, 0x4f, 0x79, 0x62, 0x3f } };
#endif

    // Defina um macro para exportar funções (no Windows)
#ifdef _WIN32
#define DART_MSSQL_EXPORT __declspec(dllexport)
#else
#define DART_MSSQL_EXPORT
#endif

    constexpr auto ROUNDUP_AMOUNT = 8;
#define ROUNDUP_(size, amount) (((DBBYTEOFFSET)(size) + ((amount) - 1)) & ~((DBBYTEOFFSET)(amount) - 1))
#define ROUNDUP(size)          ROUNDUP_(size, ROUNDUP_AMOUNT)

    // Declarações das funções

    // Inicializa o ambiente COM.
    DART_MSSQL_EXPORT HRESULT initializeCOM();

    // Funções de conversão de strings.
    DART_MSSQL_EXPORT BSTR UTF8ToBSTR(const char* utf8Value);
    DART_MSSQL_EXPORT char* WideCharToUTF8(const wchar_t* value);
    DART_MSSQL_EXPORT BSTR intToBSTR(int number);

    // Função auxiliar para adicionar mensagens de erro.
    DART_MSSQL_EXPORT void addError(int* errorCount, char* errorMessages, int errorMsgBufferSize, const char* msg);

    // Função auxiliar para verificação de HRESULT.
    DART_MSSQL_EXPORT HRESULT oleCheck(HRESULT hr, IUnknown* pObjectWithError, REFIID IID_InterfaceWithError,
        int* errorCount, char* errorMessages, int errorMsgBufferSize);

    // Função auxiliar para exibir informações de erro (placeholder).
    DART_MSSQL_EXPORT void DumpErrorInfo(IUnknown* pObjectWithError, REFIID IID_InterfaceWithError,
        int* errorCount, char* errorMessages, int errorMsgBufferSize);

    // Verifica memória e adiciona erro se necessário.
    DART_MSSQL_EXPORT HRESULT memoryCheck(HRESULT hr, void* pv, int* errorCount,
        char* errorMessages, int errorMsgBufferSize);

    // Libera os bindings alocados.
    DART_MSSQL_EXPORT void freeBindings(DBORDINAL cBindings, DBBINDING* rgBindings);

    // Cria um accessor para dados "curtos" (placeholder).
    DART_MSSQL_EXPORT HRESULT createShortDataAccessor(IUnknown* pUnkRowset, HACCESSOR* phAccessor,
        DBORDINAL* pcBindings, DBBINDING** prgBindings,
        DBORDINAL cColumns, DBCOLUMNINFO* rgColumnInfo,
        DBORDINAL* pcbRowSize, int* errorCount,
        char* errorMessages, int errorMsgBufferSize);

    // Cria accessors para dados "longos" (placeholder).
    DART_MSSQL_EXPORT HRESULT createLargeDataAcessors(IUnknown* pUnkRowset, HACCESSOR** phAccessors,
        DBORDINAL* pcBindings, DBBINDING** prgBindings,
        DBORDINAL cColumns, DBCOLUMNINFO* rgColumnInfo,
        int* errorCount, char* errorMessages, int errorMsgBufferSize);

    // Cria um accessor para parâmetros SQL (placeholder).
    DART_MSSQL_EXPORT HRESULT createParamsAccessor(IUnknown* pUnkRowset, HACCESSOR* phAccessor,
        DBCOUNTITEM sqlParamsCount,
        DBORDINAL* pcbRowSize, void** ppParamData,
        int* errorCount, char* errorMessages, int errorMsgBufferSize);

    // Conecta ao banco de dados com os parâmetros informados.
    DART_MSSQL_EXPORT HRESULT sqlConnect(const char* serverName,
        const char* dbName,
        const char* userName,
        const char* password,
        int64_t authType,
        IDBInitialize** ppInitialize,
        int* errorCount,
        char* errorMessages,
        int errorMsgBufferSize);

    /// Executa um comando SQL e retorna uma string (ex.: JSON) com os resultados.
    /// Essa função não depende mais da API Dart.
    DART_MSSQL_EXPORT char* sqlExecute(IDBInitialize* pInitialize,
        const LPCOLESTR sqlCommand,
        int* errorCount,
        char* errorMessages,
        int errorMsgBufferSize);

#ifdef __cplusplus
}
#endif
