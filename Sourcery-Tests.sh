#!/bin/bash

sourcery --sources Tests/MeowTests --templates Templates --output Tests/MeowTests/Generated.swift "$@"
