/*
 * vf_conf.m: data structures and functions to configure the VF Driver
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

#include "configmake.h"
#include "vircommand.h"
#include "virconf.h"
#include "virfile.h"
#include "virlog.h"
#include "virobject.h"
#include "virstring.h"
#include "virutil.h"
#include "capabilities.h"
#include "domain_conf.h"

#include "vf_domain.h"
#include "vf_conf.h"

VIR_LOG_INIT("vf.vf_conf");

@implementation virVFDriver
    - (uint64_t) allocateVMID {
        @synchronized(self) {
            self.vmid++;
            return self.vmid;
        }
    }
    - (void) initConfiguration {
        self.cfg = g_new0(virVFConf, 1);
        self.cfg->configBaseDir = virGetUserConfigDirectory();

        self.cfg->configDir = g_strdup_printf("%s/vf", self.cfg->configBaseDir);
        self.cfg->nvramDir = g_strdup_printf("%s/nvram", self.cfg->configDir);
    }

    - (void) destroyConfiguration {
        g_free(self.cfg->configDir);
        g_free(self.cfg->nvramDir);

        g_free(self.cfg->configBaseDir);
        g_free(self.cfg);
    }
@end


virCaps *virVFDriverCapsInit(void)
{
    g_autoptr(virCaps) caps = NULL;
    virCapsGuest *guest;

    if ((caps = virCapabilitiesNew(virArchFromHost(),
                                   false, false)) == NULL)
        return NULL;

    if (!(caps->host.numa = virCapabilitiesHostNUMANewHost()))
        return NULL;

    guest = virCapabilitiesAddGuest(caps, VIR_DOMAIN_OSTYPE_HVM,
                                    caps->host.arch, NULL, NULL, 0, NULL);

    virCapabilitiesAddGuestDomain(guest, VIR_DOMAIN_VIRT_VF,
                                    NULL, NULL, 0, NULL);

    return g_steal_pointer(&caps);
}


virDomainXMLOption *
virVFDriverCreateXMLConf(virVFDriver *driver)
{
    virDomainXMLOption *ret = NULL;

    ret = virDomainXMLOptionNew(NULL,
                                &virVFDriverPrivateDataCallbacks,
                                NULL,
                                NULL,
                                NULL,
                                NULL);

    return ret;
}
