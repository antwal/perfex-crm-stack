<?php

defined('BASEPATH') or exit('No direct script access allowed');

/*
Module Name: Sample Module
Description: A minimal example module for the Perfex CRM Stack Docker template. It does nothing useful: it shows the shape a module needs to be deployed, tested on several PHP versions and checked against the test instance.
Version: 0.1.0
Requires at least: 3.4.0
*/

// The classes of the module are loaded by Composer. deploy.sh runs "composer install --no-dev" in the module's folder on the
// server before copying it into the application, so vendor/ is there.
if (is_file(__DIR__ . '/vendor/autoload.php')) {
    require_once __DIR__ . '/vendor/autoload.php';
}

define('SAMPLE_MODULE_NAME', 'sample_module');

// Runs once, when the module is activated from Setup > Modules. A module with tables of its own creates them here.
register_activation_hook(SAMPLE_MODULE_NAME, 'sample_module_activation_hook');

function sample_module_activation_hook(): void
{
    // Nothing to create: this module has no tables.
}
