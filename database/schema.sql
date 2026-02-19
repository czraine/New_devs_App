-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Tenants Table
CREATE TABLE tenants (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Properties Table
CREATE TABLE properties (
    id TEXT NOT NULL, -- Not PK solely, might be composite with tenant in real world, but strict ID here
    tenant_id TEXT REFERENCES tenants(id),
    name TEXT NOT NULL,
    timezone TEXT NOT NULL DEFAULT 'UTC',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (id, tenant_id)
);

-- Reservations Table
CREATE TABLE reservations (
    id TEXT PRIMARY KEY,
    property_id TEXT,
    tenant_id TEXT REFERENCES tenants(id),
    check_in_date TIMESTAMP WITH TIME ZONE NOT NULL,
    check_out_date TIMESTAMP WITH TIME ZONE NOT NULL,
    total_amount NUMERIC(10, 3) NOT NULL, -- storing as numeric with 3 decimals to allow sub-cent precision tracking
    currency TEXT DEFAULT 'USD',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    FOREIGN KEY (property_id, tenant_id) REFERENCES properties(id, tenant_id)
);

-- RLS Policies (Simulation)
ALTER TABLE properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations ENABLE ROW LEVEL SECURITY;

-- FIX: Create RLS policies to enforce tenant isolation
-- Properties: Users can only see their own tenant's properties
CREATE POLICY tenant_properties_isolation ON properties
    FOR ALL
    TO authenticated
    USING (tenant_id = current_setting('app.current_tenant')::TEXT);

-- Reservations: Users can only see reservations for their tenant's properties
CREATE POLICY tenant_reservations_isolation ON reservations
    FOR ALL
    TO authenticated
    USING (
        property_id IN (
            SELECT property_id FROM properties 
            WHERE tenant_id = current_setting('app.current_tenant')::TEXT
        )
    );
