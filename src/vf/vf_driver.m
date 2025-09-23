/*
 * vf_driver.m: hypervisor driver for Virtualization.Framework
 *
 * Copyright (C) 2025 Rayhan Faizel
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 */

#include <config.h>

#include <fcntl.h>

#include "internal.h"
#include "virerror.h"
#include "datatypes.h"
#include "virfile.h"
#include "virfdstream.h"
#include "viralloc.h"
#include "viruuid.h"
#include "virlog.h"
#include "domain_conf.h"
#include "domain_event.h"
#include "vircommand.h"
#include "capabilities.h"
#include "viraccessapicheck.h"
#include "virclosecallbacks.h"
#include "vf_conf.h"
#include "vf_domain.h"
#include "vf_machine.h"
#include "vf_driver.h"

#include <Foundation/Foundation.h>
#include <Virtualization/Virtualization.h>

VIR_LOG_INIT("vf.vf_driver");

static virVFDriver *vf_driver = nil;

static virDomainObj *
vfDomObjFromDomain(virDomainPtr domain)
{
    virDomainObj *vm;
    virVFDriver *driver = (__bridge virVFDriver *) domain->conn->privateData;
    char uuidstr[VIR_UUID_STRING_BUFLEN];

    vm = virDomainObjListFindByUUID(driver.domains, domain->uuid);
    if (!vm) {
        virUUIDFormat(domain->uuid, uuidstr);
        virReportError(VIR_ERR_NO_DOMAIN,
                       _("no domain with matching uuid '%1$s' (%2$s)"),
                       uuidstr, domain->name);
        return NULL;
    }

    return vm;
}


static int
vfDomainGetInfo(virDomainPtr dom,
                virDomainInfoPtr info)
{
    virDomainObj *vm;
    int ret = -1;

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainGetInfoEnsureACL(dom->conn, vm->def) < 0)
        goto cleanup;

    info->state = virDomainObjGetState(vm, NULL);

    info->cpuTime = 0;

    info->memory = vm->def->mem.cur_balloon;
    info->maxMem = virDomainDefGetMemoryTotal(vm->def);
    info->nrVirtCpu = virDomainDefGetVcpus(vm->def);
    ret = 0;

 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int
vfDomainGetState(virDomainPtr dom,
                   int *state,
                   int *reason,
                   unsigned int flags)
{
    virDomainObj *vm;
    int ret = -1;

    virCheckFlags(0, -1);

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainGetStateEnsureACL(dom->conn, vm->def) < 0)
        goto cleanup;

    *state = virDomainObjGetState(vm, reason);
    ret = 0;

 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int vfDomainIsPersistent(virDomainPtr dom)
{
    virDomainObj *obj;
    int ret = -1;

    if (!(obj = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainIsPersistentEnsureACL(dom->conn, obj->def) < 0)
        goto cleanup;

    ret = obj->persistent;

 cleanup:
    virDomainObjEndAPI(&obj);
    return ret;
}


static int vfDomainIsActive(virDomainPtr dom)
{
    virDomainObj *obj;
    int ret = -1;

    if (!(obj = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainIsActiveEnsureACL(dom->conn, obj->def) < 0)
        goto cleanup;

    ret = virDomainObjIsActive(obj);

 cleanup:
    virDomainObjEndAPI(&obj);
    return ret;
}


static virDomainPtr vfDomainLookupByUUID(virConnectPtr conn,
                                          const unsigned char *uuid)
{
    virVFDriver *driver = (__bridge virVFDriver *) conn->privateData;
    virDomainObj *vm;
    virDomainPtr dom = NULL;

    vm = virDomainObjListFindByUUID(driver.domains, uuid);

    if (!vm) {
        char uuidstr[VIR_UUID_STRING_BUFLEN];
        virUUIDFormat(uuid, uuidstr);
        virReportError(VIR_ERR_NO_DOMAIN,
                       _("No domain with matching uuid '%1$s'"), uuidstr);
        goto cleanup;
    }

    if (virDomainLookupByUUIDEnsureACL(conn, vm->def) < 0)
        goto cleanup;

    dom = virGetDomain(conn, vm->def->name, vm->def->uuid, vm->def->id);

 cleanup:
    virDomainObjEndAPI(&vm);
    return dom;
}


static virDomainPtr vfDomainLookupByName(virConnectPtr conn,
                                           const char *name)
{
    virVFDriver *driver = (__bridge virVFDriver *) conn->privateData;
    virDomainObj *vm;
    virDomainPtr dom = NULL;

    vm = virDomainObjListFindByName(driver.domains, name);

    if (!vm) {
        virReportError(VIR_ERR_NO_DOMAIN,
                       _("no domain with matching name '%1$s'"), name);
        goto cleanup;
    }

    if (virDomainLookupByNameEnsureACL(conn, vm->def) < 0)
        goto cleanup;

    dom = virGetDomain(conn, vm->def->name, vm->def->uuid, vm->def->id);

 cleanup:
    virDomainObjEndAPI(&vm);
    return dom;
}


static int
vfConnectListAllDomains(virConnectPtr conn,
                        virDomainPtr **domains,
                        unsigned int flags)
{
    virVFDriver *driver = (__bridge virVFDriver *) conn->privateData;

    virCheckFlags(VIR_CONNECT_LIST_DOMAINS_FILTERS_ALL, -1);

    if (virConnectListAllDomainsEnsureACL(conn) < 0)
        return -1;

    return virDomainObjListExport(driver.domains, conn, domains,
                                  virConnectListAllDomainsCheckACL, flags);
}


static int
vfDomainOpenConsole(virDomainPtr dom,
                    const char *dev_name,
                    virStreamPtr st,
                    unsigned int flags)
{
    virDomainObj *vm = NULL;
    int ret = -1;
    virDomainChrDef *chr = NULL;

    virCheckFlags(0, -1);

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainOpenConsoleEnsureACL(dom->conn, vm->def) < 0)
        goto cleanup;

    if (virDomainObjCheckActive(vm) < 0)
        goto cleanup;

    if (vm->def->nserials)
        chr = vm->def->serials[0];

    if (!chr) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                       _("cannot find console device '%1$s'"),
                       dev_name ? dev_name : _("default"));
        goto cleanup;
    }

    if (chr->source->type != VIR_DOMAIN_CHR_TYPE_PTY) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                       _("character device %1$s is not using a PTY"),
                       dev_name ? dev_name : NULLSTR(chr->info.alias));
        goto cleanup;
    }

    if (virFDStreamOpenPTY(st, chr->source->data.file.path,
                           0, 0, O_RDWR) < 0)
        goto cleanup;

    ret = 0;
 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int
vfDomainDestroyFlags(virDomainPtr dom, unsigned int flags)
{
    virConnectPtr conn = dom->conn;
    virVFDriver *driver = (__bridge virVFDriver *) conn->privateData;
    virDomainObj *vm;
    vfDomainObjPrivate *priv;
    int ret = -1;

    virCheckFlags(0, -1);

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainDestroyFlagsEnsureACL(conn, vm->def) < 0)
        goto cleanup;

    if (virDomainObjCheckActive(vm) < 0)
        goto cleanup;

    ret = vfStopMachine(driver, vm);

    if (ret)
        goto cleanup;

    priv = (__bridge vfDomainObjPrivate *) vm->privateData;

    [priv.delegate stopVMForReason:VIR_DOMAIN_SHUTOFF_DESTROYED lockNeeded:NO];

    if (!vm->persistent)
        virDomainObjListRemove(driver.domains, vm);

    cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int
vfDomainDestroy(virDomainPtr dom)
{
    return vfDomainDestroyFlags(dom, 0);
}


static int
vfDomainShutdownFlags(virDomainPtr dom, unsigned int flags)
{
    virDomainObj *vm;
    virVFDriver *driver = (__bridge virVFDriver *) dom->conn->privateData;
    __block vfDomainObjPrivate *priv;
    __block NSError *error;
    int ret = -1;

    virCheckFlags(0, -1);

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainShutdownFlagsEnsureACL(dom->conn, vm->def, flags) < 0)
        goto cleanup;

    if (virDomainObjCheckActive(vm) < 0)
        goto cleanup;

    priv = (__bridge vfDomainObjPrivate *) vm->privateData;

    dispatch_sync(driver.queue, ^{
        [priv.machine requestStopWithError:&error];
    });

    if (error) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                _("unable to shutdown domain: '%1$s'"),
                vm->def->name);
        goto cleanup;
    }

    ret = 0;
 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int
vfDomainShutdown(virDomainPtr dom)
{
    return vfDomainShutdownFlags(dom, 0);
}


static char *vfDomainGetXMLDesc(virDomainPtr dom,
                                unsigned int flags)
{
    virVFDriver *driver = (__bridge virVFDriver *) dom->conn->privateData;
    virDomainObj *vm;
    char *ret = NULL;

    virCheckFlags(VIR_DOMAIN_XML_COMMON_FLAGS, NULL);

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainGetXMLDescEnsureACL(dom->conn, vm->def, flags) < 0)
        goto cleanup;

    ret = virDomainDefFormat((flags & VIR_DOMAIN_XML_INACTIVE) &&
                             vm->newDef ? vm->newDef : vm->def,
                             driver.xmlopt,
                             virDomainDefFormatConvertXMLFlags(flags));

 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static virDomainPtr
vfDomainDefineXMLFlags(virConnectPtr conn,
                  const char *xml,
                  unsigned int flags G_GNUC_UNUSED)
{
    virVFDriver *driver = (__bridge virVFDriver *) (conn->privateData);
    virVFConf *cfg = driver.cfg;
    g_autoptr(virDomainDef) def = NULL;
    g_autoptr(virDomainDef) oldDef = NULL;
    virDomainObj *vm = NULL;
    virDomainPtr dom = NULL;
    unsigned int parse_flags = VIR_DOMAIN_DEF_PARSE_INACTIVE;

    if ((def = virDomainDefParseString(xml, driver.xmlopt,
                                       NULL, parse_flags)) == NULL)
        goto cleanup;

    if (virDomainDefineXMLFlagsEnsureACL(conn, def) < 0)
        goto cleanup;

    if (!(vm = virDomainObjListAdd(driver.domains,
                                   &def,
                                   driver.xmlopt,
                                   0,
                                   &oldDef)))
        goto cleanup;

    vm->persistent = 1;

    if (virDomainDefSave(vm->newDef ? vm->newDef : vm->def,
                         driver.xmlopt, cfg->configDir) < 0) {
        virDomainObjListRemove(driver.domains, vm);
        goto cleanup;
    }

    dom = virGetDomain(conn, vm->def->name, vm->def->uuid, vm->def->id);

    cleanup:
    virDomainObjEndAPI(&vm);
    return dom;
}


static virDomainPtr
vfDomainDefineXML(virConnectPtr conn,
                  const char *xml)
{
    return vfDomainDefineXMLFlags(conn, xml, 0);
}


static int vfDomainCreateWithFiles(virDomainPtr dom,
                                    unsigned int nfiles G_GNUC_UNUSED,
                                    int *files G_GNUC_UNUSED,
                                    unsigned int flags G_GNUC_UNUSED)
{
    virVFDriver *driver = (__bridge virVFDriver *) dom->conn->privateData;
    virDomainObj *vm;
    int ret = -1;

    if (!(vm = vfDomObjFromDomain(dom)))
        goto cleanup;

    if (virDomainCreateWithFilesEnsureACL(dom->conn, vm->def) < 0)
        goto cleanup;

    if (virDomainObjIsActive(vm)) {
        virReportError(VIR_ERR_OPERATION_INVALID,
                       "%s", _("Domain is already running"));
        goto cleanup;
    }

    ret = vfStartMachine(driver, vm);

 cleanup:
    virDomainObjEndAPI(&vm);
    return ret;
}


static int vfDomainCreate(virDomainPtr dom)
{
    return vfDomainCreateWithFiles(dom, 0, NULL, 0);
}


static virDomainPtr
vfDomainCreateXML(virConnectPtr conn,
                  const char *xml,
                  unsigned int flags G_GNUC_UNUSED)
{
    virVFDriver *driver = (__bridge virVFDriver *) (conn->privateData);
    virDomainDef *def;
    virDomainObj *vm = NULL;
    virDomainPtr dom = NULL;
    unsigned int parse_flags = VIR_DOMAIN_DEF_PARSE_INACTIVE;

    if ((def = virDomainDefParseString(xml, driver.xmlopt,
                                       NULL, parse_flags)) == NULL)
        goto cleanup;

    if (virDomainCreateXMLEnsureACL(conn, def) < 0)
        goto cleanup;

    if (!(vm = virDomainObjListAdd(driver.domains,
                                   &def,
                                   driver.xmlopt,
                                   VIR_DOMAIN_OBJ_LIST_ADD_LIVE |
                                   VIR_DOMAIN_OBJ_LIST_ADD_CHECK_LIVE,
                                   NULL)))
        goto cleanup;

    if (vfStartMachine(driver, vm) < 0) {
        if (!vm->persistent)
            virDomainObjListRemove(driver.domains, vm);

        goto cleanup;
    }

    dom = virGetDomain(conn, vm->def->name, vm->def->uuid, vm->def->id);

    cleanup:
    virDomainObjEndAPI(&vm);
    return dom;
}


static char *vfConnectGetCapabilities(virConnectPtr conn G_GNUC_UNUSED)
{
    g_autoptr(virCaps) caps = NULL;
    char *xml;

    if (virConnectGetCapabilitiesEnsureACL(conn) < 0)
        return NULL;

    if (!(caps = virVFDriverCapsInit()))
        return NULL;

    xml = virCapabilitiesFormatXML(caps);

    return xml;
}


static int vfConnectGetVersion(virConnectPtr conn,
                               unsigned long *version)
{
    if (virConnectGetVersionEnsureACL(conn) < 0)
        return -1;

    *version = 0;
    return 0;
}


static virDrvOpenStatus
vfConnectOpen(virConnectPtr conn,
              virConnectAuthPtr auth G_GNUC_UNUSED,
              virConf *conf G_GNUC_UNUSED,
              unsigned int flags G_GNUC_UNUSED)
{
    if (vf_driver == nil) {
        virReportError(VIR_ERR_INTERNAL_ERROR, "%s",
                       _("vf state driver is not active"));
        return VIR_DRV_OPEN_ERROR;
    }

    if (virConnectOpenEnsureACL(conn) < 0)
        return VIR_DRV_OPEN_ERROR;

    conn->privateData = CFBridgingRetain(vf_driver);

    return VIR_DRV_OPEN_SUCCESS;
}


static int
vfConnectClose(virConnectPtr conn)
{
    virVFDriver *driver = (__bridge virVFDriver *) (conn->privateData);

    virCloseCallbacksDomainRunForConn(driver.domains, conn);

    CFRelease(conn->privateData);

    return 0;
}


static virDrvStateInitResult
vfStateInitialize(bool privileged G_GNUC_UNUSED,
                  const char *root G_GNUC_UNUSED,
                  bool monolithic G_GNUC_UNUSED,
                  virStateInhibitCallback callback G_GNUC_UNUSED,
                  void *opaque G_GNUC_UNUSED)
{
    virVFDriver *driver = [[virVFDriver alloc] init];
    virVFConf *cfg;
    if (![VZVirtualMachine isSupported]) {
        VIR_INFO("Virtualization.Framework not supported on this machine. Skipping driver.");
        return VIR_DRV_STATE_INIT_SKIPPED;
    }

    if (!(driver.xmlopt = virVFDriverCreateXMLConf(driver)))
        return VIR_DRV_STATE_INIT_ERROR;

    if (!(driver.domains = virDomainObjListNew()))
        return VIR_DRV_STATE_INIT_ERROR;

    driver.queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);

    driver.vmid = 0;

    [driver initConfiguration];
    cfg = driver.cfg;

    if (g_mkdir_with_parents(cfg->nvramDir, 0777) < 0) {
        virReportError(VIR_ERR_INTERNAL_ERROR, "Failed to create nvram dir: %s",
                       _(cfg->nvramDir));
        [driver initConfiguration];
        return VIR_DRV_STATE_INIT_ERROR;
    }

    /* Load persistent configs */
    if (virDomainObjListLoadAllConfigs(driver.domains,
                                       cfg->configDir,
                                       NULL, false,
                                       driver.xmlopt,
                                       NULL, NULL) < 0)
    {
        [driver destroyConfiguration];
        return VIR_DRV_STATE_INIT_ERROR;
    }

    vf_driver = driver;
    return VIR_DRV_STATE_INIT_COMPLETE;
}


static int vfStateCleanup(void)
{
    virObjectUnref(vf_driver.xmlopt);
    virObjectUnref(vf_driver.domains);

    [vf_driver destroyConfiguration];

    vf_driver = nil;

    return 0;
}


static virHypervisorDriver vfHypervisorDriver = {
    .name = "Virtualization.Framework",
    .connectOpen = vfConnectOpen, /* 11.8.0 */
    .connectClose = vfConnectClose, /* 11.8.0 */
    .connectGetCapabilities = vfConnectGetCapabilities, /* 11.8.0 */
    .domainCreateXML = vfDomainCreateXML, /* 11.8.0 */
    .domainDefineXML = vfDomainDefineXML, /* 11.8.0 */
    .domainDefineXMLFlags = vfDomainDefineXMLFlags, /* 11.8.0 */
    .domainCreate = vfDomainCreate, /* 11.8.0 */
    .domainCreateWithFiles = vfDomainCreateWithFiles, /* 11.8.0 */
    .domainGetXMLDesc = vfDomainGetXMLDesc, /* 11.8.0 */
    .domainShutdown = vfDomainShutdown, /* 11.8.0 */
    .domainShutdownFlags = vfDomainShutdownFlags, /* 11.8.0 */
    .domainDestroy = vfDomainDestroy, /* 11.8.0 */
    .domainDestroyFlags = vfDomainDestroyFlags, /* 11.8.0 */
    .domainLookupByName = vfDomainLookupByName, /* 11.8.0 */
    .domainLookupByUUID = vfDomainLookupByUUID, /* 11.8.0 */
    .domainGetInfo = vfDomainGetInfo, /* 11.8.0 */
    .domainIsActive = vfDomainIsActive, /* 11.8.0 */
    .domainIsPersistent = vfDomainIsPersistent, /* 11.8.0 */
    .domainGetState = vfDomainGetState, /* 11.8.0 */
    .domainOpenConsole = vfDomainOpenConsole, /* 11.8.0 */
    .connectListAllDomains = vfConnectListAllDomains, /* 11.8.0 */
    .connectGetVersion = vfConnectGetVersion, /* 11.8.0 */
};

static virStateDriver vfStateDriver = {
    .name = "Virtualization.Framework",
    .stateInitialize = vfStateInitialize,
    .stateCleanup = vfStateCleanup,
};

static virConnectDriver vfConnectDriver = {
    .localOnly = true,
    .uriSchemes = (const char *[]){ "vf", NULL },
    .hypervisorDriver = &vfHypervisorDriver,
};

int vfRegister(void)
{
    if (virRegisterConnectDriver(&vfConnectDriver,
                                 true) < 0)
        return -1;
    if (virRegisterStateDriver(&vfStateDriver) < 0)
        return -1;

    return 0;
}
