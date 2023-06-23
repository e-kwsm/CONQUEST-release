import numpy as np
import os
import pytest

def read_conquest_out(path=".", filename="Conquest_out"):
    '''
    Reads a predefined set of values from a Conquest output file (typically
    named Conquest_out) by matching a string on the line. Currently we read
    Harris-Foulkes energy, Maximum force, Force Residual and Total stress.
    Returns a dictionary with float values.
    '''
    path_to_file = os.path.join(path,filename)
    assert os.path.exists(path_to_file)
    file = open(path_to_file, 'r')
    Results = dict()
    for line in file.readlines():
        if line.find("Harris-Foulkes energy") >= 0:
            Results['Harris-Foulkes energy'] = float(line.split("=")[1].split()[0])
        if line.find("Maximum force") >= 0:
            Results['Max force'] = float(line.split(":")[2].split("(")[0])
        if line.find("Force Residual") >= 0:
            Results['Force residual'] = float(line.split(":")[2].split()[0])
        if line.find("Total stress") >= 0:
            Results['Total stress'] = np.array(line.split(":")[2].split()[:-1], dtype=float)
        if line.find("Total polarisation") >= 0:
            Results['Total polarisation'] = float(line.split(":")[1].split()[0])

    return Results

@pytest.mark.parametrize("test_path", ["test_001_bulk_Si_1proc_Diag",
                                       "test_002_bulk_Si_1proc_OrderN",
                                       "test_003_bulk_BTO_polarisation"])
@pytest.mark.parametrize("key",['Harris-Foulkes energy',
                                'Max force',
                                'Force residual',
                                'Total stress',
                                'Total polarisation',
                                ])
def test_check_outputs(test_path, key):
    '''
    Reads a predefined set of results written in Conquest_out files of
    tests 001 - 003 and compares them against results in Conquest_out.ref
    within a relative tolerance.
    '''

    # Only check polarisation for test003 for now
    xfail_test = (key == "Total polarisation" and "test_003" not in test_path)
    if (xfail_test):
        pytest.xfail("invalid parameter combination: "+test_path+", "+key)

    # Read data from the directory parameterized by test_path
    ref_result = read_conquest_out(test_path, "Conquest_out.ref")
    test_result = read_conquest_out(test_path, "Conquest_out")

    # Set precision, by default check to 6 decimal numbers
    default_precision = 1e-4
    
    np.testing.assert_allclose(ref_result[key],
                               test_result[key],
                               rtol = default_precision,
                               atol = 0,
                               err_msg = test_path+": "+key,
                               verbose = True)
