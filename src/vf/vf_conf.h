/*
 * vf_conf.h: data structures and functions to configure the VF Driver
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

#pragma once

#include <config.h>

#include "internal.h"
#include "virdomainobjlist.h"

#include <Foundation/Foundation.h>
#include <Virtualization/Virtualization.h>

#define VIR_FROM_THIS VIR_FROM_VF

struct _virVFConf {
    char *configBaseDir;
    char *configDir;
    char *nvramDir;
};

typedef struct _virVFConf virVFConf;

@interface virVFDriver: NSObject

    @property virDomainXMLOption *xmlopt;

    /* Immutable pointer, self-locking APIs */
    @property virDomainObjList *domains;

    @property (nonatomic, strong) dispatch_queue_t queue;

    @property (atomic) uint64_t vmid;

    @property virVFConf *cfg;

    - (uint64_t) allocateVMID;

    - (void) initConfiguration;

    - (void) destroyConfiguration;
@end

virCaps *virVFDriverCapsInit(void);

virDomainXMLOption *virVFDriverCreateXMLConf(virVFDriver *driver);
